# pag-swift

使用 Swift 6.4 重写的经典 PAG 动画库，通过 Metal 在 SwiftUI、UIKit 和 AppKit 中播放。库使用系统框架，不依赖上游 libpag 二进制。

- [使用说明](USAGE.md)：接入、播放、动态文字/图片/视频、缓存和错误处理。
- [项目检查报告](Docs/项目检查报告.md)：2026-10-23 的功能核对、优化、实测结果和剩余风险。
- [核心合同](Docs/核心实现.md)与[架构设计](Docs/架构设计.md)：实现范围和内部约束。
- [动态内容业务接入](Docs/动态内容业务接入.md)：槽位、宿主动图、遮罩及业务适配。
- [格式支持矩阵](Docs/格式支持矩阵.md)：格式证据与历史验收记录。

最低系统为 iOS 26 / macOS 26。远程 SPM 直接使用仓库根，product 为 `pag-swift`，Swift 导入名为 `pag_swift`。本地开发与测试仍用 `packages/pag-swift`。Demo 在 `app/pag-swift-demo`。

```sh
swift test --package-path packages/pag-swift -j 4
```

当前仓库的 126 份 PAG 样例通过首、中、末帧的加载和 Metal 输入准备，包括小尺寸缩放宿主。此结果不等于完整 PAG 格式兼容，也不等于所有设备上的逐帧视觉及性能验收。
