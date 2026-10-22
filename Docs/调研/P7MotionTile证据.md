# P7 MotionTile 图像层证据（2026-10-21）

上游只读源码 `src/codec/tags/effects/MotionTileEffect.cpp::ReadMotionTileEffect` 和 `include/pag/file.h::MotionTileEffect` 定义 tag56 的十项统一 flags：Spatial tileCenter、Simple tileWidth/tileHeight/outputWidth/outputHeight、Discrete mirrorEdges、Simple phase、Discrete horizontalPhaseShift、Simple effectOpacity、mask 引用列表。`src/rendering/filters/MotionTileFilter.cpp::Apply/filterBounds` 证明 tileCenter 相对于**输入内容 bounds** 归一，输出矩形围绕输入 bounds 中心按输出百分比扩张。其片元按 floor 型 mod 重复、0.005 边缘钳制、奇数块镜像；phase 仅在正值时沿交错行或列移动取样。源码还表明效果先于图层样式处理，因而不能把输入蒙版误施加在平铺结果之后。

`PAGMotionTileEvidenceTests` 完整消费三份真实 tag56 子流，均为 Image 层、静态、tileWidth/Height=100、phase=0、effectOpacity=255、无效果 mask 引用：

| 文件 | 中心 | 输出 | 镜像 | 后续门禁 |
| --- | --- | --- | --- | --- |
| `motiontile1.pag` | (200, 360) | 300% × 300% | 否 | 无；完整通过 |
| `MT2.pag` | (429, 625) | 200% × 200% | 是 | 另一层的动态 `motionBlur` |
| `motiontile_text_corner.pag` | (256, 256) | 300% × 300% | 否 | `layerTag:58` CornerPin |

字段调查日志：`/private/tmp/pag-motion-tile-field-audit3.log`。先修 [架构合同](../架构设计.md) 第 P7 MotionTile 段，再实现 `SourceMotionTile`、tag56 解码、帧采样和专用 Metal 片元。输入原图纹理由既有图片路径提供，扩大图像四边形后仍直接画到根 drawable；没有新增整帧中转或 CPU 读回。非 Image、非默认效果 opacity、非空效果 mask、图层 mask、同层投影、替换图片裁边等尚无直采等价证明的组合明确拒绝。

macOS 的 `MetalMotionTileFileTests` 通过公开 Loader 验证 `motiontile1.pag` 进入根 drawable 批次，并在已挂载 drawable 对比开启/去掉效果的同源像素。两色语义输入另有镜像奇偶的红红绿绿、正 phase 交错的绿红像素金值；它们只证明 Metal 取样分支，不冒充真实 `.pag` 字节。完整库复测 **1412 项/268 组通过**（`/private/tmp/pag-motion-tile-final-full.log`）；首次全库因既有播放器移交测试 60 秒超时失败，该项隔离 0.076 秒通过后完整重跑通过。126 资源审计 **110 通过/16 明确 unsupported**，只有 `motiontile1.pag` 从旧 109/17 新增通过，日志 `/private/tmp/pag-motion-tile-audit.log`。尚无上游逐像素金图或正式 Demo 整帧视觉对照；镜像和 phase 的真实文件组合还受其它独立门禁。
