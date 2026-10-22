import Metal

/// 无前置效果预合成的局部MotionBlur结果接线；根组仍由主构建器负责。
extension MetalFrameBuilder {
    /// 将已组合内容映射到1.2倍效果输出，最终draw继续直写drawable。
    mutating func attachPlainMotionBlur(_ layout: MappedMotionBlurLayout,
                                        content: MetalGroupAttachment,
                                        scope: MetalGroupScope) throws {
        let mesh = try resources.rectangle(budget: &budget)
        // 模糊输出可越出输入边界；只继承祖先裁剪，不能再用原预合成clip截断。
        try append(mesh: mesh, texture: content.texture, matrix: layout.outputMatrix,
            color: SIMD4(repeating: Float(scope.opacity)), clips: scope.previous,
            textBulgeMap: layout.map, motionBlur: layout.blur)
    }
}
