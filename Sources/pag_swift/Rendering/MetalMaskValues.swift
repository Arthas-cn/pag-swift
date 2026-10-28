import Metal

/// 单条普通路径clip的64字节片元常量；路径覆盖与图元覆盖各自独立计算后相乘。
struct MetalMaskUniforms {
    /// 蒙版网格局部坐标到最终显示像素x的实际Float行。
    let horizontalPixels: SIMD4<Float>
    /// 蒙版网格局部坐标到最终显示像素y的实际Float行。
    let verticalPixels: SIMD4<Float>
    /// 上述实际Float矩阵的逆线性两行，用于BVH保守查询。
    let inverse: SIMD4<Float>
    /// BVH节点数、补集位与两个零保留字段；零节点不得送入GPU查询。
    let options: SIMD4<UInt32>

    /// 固定实际上传变换和节点数；超出GPU索引范围明确失败。
    init(transform: MetalDrawTransform, nodeCount: Int, inverted: Bool) throws {
        guard let count = UInt32(exactly: nodeCount), count > 0 else {
            throw PAGError.resourceLimitExceeded("metalMaskNodes")
        }
        horizontalPixels = transform.horizontal
        verticalPixels = transform.vertical
        inverse = transform.inverse
        options = SIMD4(count, inverted ? 1 : 0, 0, 0)
    }
}

/// 同一帧GPU保活的有限蒙版网格与片元常量；零面积路径无需创建此输入。
struct MetalMaskInput {
    /// 不可变顶点和BVH，保活到command buffer完成。
    let mesh: MetalMesh
    /// 与网格实际Float坐标严格匹配的覆盖查询常量。
    let uniforms: MetalMaskUniforms
}
