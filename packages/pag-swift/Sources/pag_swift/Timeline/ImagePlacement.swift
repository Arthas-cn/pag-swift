/// 源图像与替换图像各自的局部布局；不改动图层矩阵或输入像素。
enum ImagePlacement {
    /// 原图先反向还原编码 scale，再减裁边 anchor，遵循 ImageBytesCache::Get。
    static func original(_ source: SourceImage) throws -> SceneAffine {
        try SceneAffine.scale(x: 1 / source.scaleFactor, y: 1 / source.scaleFactor)
            .following(.translation(x: -source.anchor.x, y: -source.anchor.y))
    }

    /// 按文件模式适配完整逻辑尺寸，不继承原图裁边；尺寸运算不可表示时抛invalidArgument。
    static func replacement(_ image: PAGImage, source: SourceImage, mode: PAGScaleMode) throws -> SceneAffine {
        // ApplyScaleMode的None保持局部左上原点；最终显示目标的none居中，不能套用其平移。
        if mode == .none { return .identity }
        return try SceneAffine(display: DisplayTransform(contentSize: image.size, targetSize: source.logicalSize,
                                                         scale: 1, mode: mode))
    }
}
