import simd

/// 上游相邻内容帧矩阵的Float快照；只决定是否跳过及纹理域速度，不持有像素。
struct MotionBlurSampling: Sendable {
    /// 上一内容帧经控制父链合成后的二维矩阵，已按TGFX float域窄化。
    let previous: MotionBlurMatrix
    /// 当前内容帧经同一父链合成后的二维矩阵。
    let current: MotionBlurMatrix

    /// 上游按完整Float矩阵逐项比较；相等时根本不安装滤镜。
    var shouldSkip: Bool { previous == current }

    /// 只比较两个轴向缩放分量；上游据此将采样中心选为0或0.5。
    var velocityCenter: Float {
        previous.a != current.a || previous.d != current.d ? 0 : 0.5
    }

    /// 从两个有限场景矩阵建立Float对；溢出到Float无穷时拒绝渲染。
    init(previous: SceneAffine, current: SceneAffine) throws {
        self.previous = try MotionBlurMatrix(previous)
        self.current = try MotionBlurMatrix(current)
    }

    /// Effects之后的完整输入范围按中心扩大1.2倍；相邻矩阵相等时保持原范围。
    func outputBounds(for input: RenderBounds) throws -> RenderBounds {
        guard !shouldSkip else { return input }
        let width = input.right - input.left
        let height = input.bottom - input.top
        return try RenderBounds(left: input.left - width * 0.1, top: input.top - height * 0.1,
                                right: input.right + width * 0.1, bottom: input.bottom + height * 0.1)
    }

    /// 将上游`ToTextureMatrix`的平移与宽高共轭作用于语义输入域；紧附件尺寸不得代入。
    func textureTransforms(in bounds: RenderBounds) throws -> MotionBlurTextureTransforms {
        let width = Float(bounds.right - bounds.left)
        let height = Float(bounds.bottom - bounds.top)
        let left = Float(bounds.left)
        let top = Float(bounds.top)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              left.isFinite, top.isFinite else {
            throw PAGError.renderingFailure("motionBlurInputBounds")
        }
        return try MotionBlurTextureTransforms(previous: previous.textureTransform(left: left, top: top,
                                                    width: width, height: height),
                                               current: current.textureTransform(left: left, top: top,
                                                    width: width, height: height),
                                               velocityCenter: velocityCenter)
    }
}

/// 与TGFX Matrix前六个Float系数对应的纯值矩阵；比较发生在纹理归一化之前。
struct MotionBlurMatrix: Sendable, Equatable {
    /// 局部x到父x的Float系数。
    let a: Float
    /// 局部x到父y的Float系数。
    let b: Float
    /// 局部y到父x的Float系数。
    let c: Float
    /// 局部y到父y的Float系数。
    let d: Float
    /// 父域水平偏移。
    let tx: Float
    /// 父域垂直偏移。
    let ty: Float

    /// 收窄Swift场景矩阵以匹配上游Float比较；不允许无穷系数进入Metal常量。
    init(_ value: SceneAffine) throws {
        a = Float(value.a)
        b = Float(value.b)
        c = Float(value.c)
        d = Float(value.d)
        tx = Float(value.tx)
        ty = Float(value.ty)
        guard [a, b, c, d, tx, ty].allSatisfy(\.isFinite) else {
            throw PAGError.renderingFailure("motionBlurTransform")
        }
    }

    /// 依次做`preTranslate(bounds.origin)`及`S⁻¹ × matrix × S`，对应上游TopLeft纹理矩阵。
    func textureTransform(left: Float, top: Float, width: Float, height: Float) -> MotionBlurTextureMatrix {
        // preTranslate是右乘：原点必须先经过当前线性部分，不能直接加到tx/ty。
        let originX = a * left + c * top + tx
        let originY = b * left + d * top + ty
        return MotionBlurTextureMatrix(horizontal: SIMD3(a, c * height / width, originX / width),
                                       vertical: SIMD3(b * width / height, d, originY / height))
    }
}

/// 单个TopLeft归一纹理矩阵的两行；GPU只需二行，无透视分量。
struct MotionBlurTextureMatrix: Sendable {
    /// 归一化输入uv对父域水平位置的线性式。
    let horizontal: SIMD3<Float>
    /// 归一化输入uv对父域垂直位置的线性式。
    let vertical: SIMD3<Float>

    /// 计算上游顶点着色器对同一源uv所作的二维位置映射。
    func applying(to uv: SIMD2<Float>) -> SIMD2<Float> {
        let point = SIMD3(uv.x, uv.y, 1)
        return SIMD2(simd_dot(horizontal, point), simd_dot(vertical, point))
    }
}

/// 两个相邻纹理矩阵及采样中心；由GPU片元按上游37次规则消费。
struct MotionBlurTextureTransforms: Sendable {
    /// 上一帧纹理归一矩阵。
    let previous: MotionBlurTextureMatrix
    /// 当前帧纹理归一矩阵。
    let current: MotionBlurTextureMatrix
    /// 缩放变化为0、其余变换为0.5。
    let velocityCenter: Float

    /// 以源uv求位置差并截到长度0.1；零长度保留上游`0/0`行为供GPU处理。
    func velocity(at uv: SIMD2<Float>) -> SIMD2<Float> {
        let difference = current.applying(to: uv) - previous.applying(to: uv)
        let distance = simd_length(difference)
        return difference * (min(distance, 0.1) / distance)
    }

    /// 窄化后仍要求有限参数；几何退化或Float溢出时不可安装采样常量。
    init(previous: MotionBlurTextureMatrix, current: MotionBlurTextureMatrix,
         velocityCenter: Float) throws {
        guard [previous.horizontal.x, previous.horizontal.y, previous.horizontal.z,
               previous.vertical.x, previous.vertical.y, previous.vertical.z,
               current.horizontal.x, current.horizontal.y, current.horizontal.z,
               current.vertical.x, current.vertical.y, current.vertical.z,
               velocityCenter].allSatisfy(\.isFinite) else {
            throw PAGError.renderingFailure("motionBlurTextureMatrix")
        }
        self.previous = previous
        self.current = current
        self.velocityCenter = velocityCenter
    }
}
