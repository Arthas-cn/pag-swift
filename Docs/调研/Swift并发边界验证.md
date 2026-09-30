# Swift 与显示目标边界验证

本记录是架构阶段的本机证据，不代表渲染实现已完成。日期：2026-09-28。

## 工具链与现状

- `swift --version`：Apple Swift 6.4，`swiftlang-6.4.0.34.1`；主机 arm64 macOS 27。
- 初始包只有 `hello()` 与资源可见性测试，没有解码或播放实现。
- 初始 `Package.swift` 已启用 Approachable Concurrency，但未声明平台和 `.v6`；应在架构复核后的基础阶段补齐。
- 初始 demo 的实际 target 是 iOS/macOS 26，`SWIFT_VERSION = 6.0`；接入阶段须改为 6.4。工程级模板值不代表 target 最终值。

## 严格并发探针

在 `/tmp` 单独编译 SDK 类型约束探针，未写入生产源码。参数：`-swift-version 6 -strict-concurrency=complete -enable-upcoming-feature ApproachableConcurrency`。

结果（macOS 主机与 `arm64-apple-ios26.0` 目标均得到同样诊断；iOS 使用 Xcode 27 SDK，仅类型检查，未运行设备）：

| SDK 类型 | 满足 `T: Sendable` | 编译器证据 |
| --- | --- | --- |
| `CAMetalLayer` | 否 | `CALayer` 的 `Sendable` conformance 被明确标成 unavailable |
| `any CAMetalDrawable` | 否 | does not conform to the Sendable protocol |
| `any MTLTexture` | 否 | does not conform to the Sendable protocol |

因此，不能让主 actor 直接把这些对象传给另一个 actor 并宣称已满足严格并发。架构必须把裸对象限制在拥有者内，跨边界传值快照；显示 layer 的共享桥需要单独证明内部同步和生命周期，不能给整库补 `@unchecked Sendable`。

## SDK 头文件证据

当前 Xcode 的 `MacOSX.sdk/System/Library/Frameworks/QuartzCore.framework/Headers/CAMetalLayer.h`：

- `nextDrawable` 可能阻塞到可用 drawable 出现，默认超时约一秒，可能返回 `nil`。主 actor 不能调用它等待显示资源。
- `framebufferOnly = true` 是适合显示 attachment 的推荐设置。
- `maximumDrawableCount` 仅接受 2 或 3；已取得的 drawable 应尽早释放。

当前 Xcode 的 `ImageIO.framework/Headers/CGImageProperties.h` 声明 WebP dictionary、loop count、delay time、unclamped delay time 和 frame info array。常量存在只证明 API 可引用，不能证明每个动画 WebP 输入都可逐帧解码；必须用真实动图做帧数、时间和像素差异验收，不支持时明确失败。

## 基线测试

受运行环境限制，默认用户缓存不可写，SwiftPM 的嵌套 sandbox 也不能启动。采用任务专用临时缓存并关闭 SwiftPM 子进程 sandbox，外层工作区沙箱仍保留：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/pag-swift-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/pag-swift-module-cache \
swift test --disable-sandbox --cache-path /tmp/pag-swift-spm-cache
```

在 `packages/pag-swift` 运行，初始 2 个 Swift Testing 用例通过（其中一个仍是模板空用例）。这只验证初始包和资源，并非播放能力验收。

## 动图读取探针（限本机）

同样在 `/tmp` 编译独立 Swift 探针，只读 VAPPlayerKit 的 `Examples/Shared/Gifts`；使用 `CGImageSourceCreateWithURL`、`CGImageSourceGetCount`、`CGImageSourceCreateImageAtIndex` 和 `CGImageSourceCopyPropertiesAtIndex`：

| 输入 | 帧数 | 首/末帧解码 | 尺寸 | 帧时长元数据 |
| --- | --- | --- | --- | --- |
| `earth.gif` | 250 | 均成功 | 512 × 384 | GIF unclamped delay 0.02 秒 |
| `webp01.webp` | 10 | 均成功 | 387 × 217 | WebP unclamped delay 0.2 秒 |

这是 macOS 27 主机的有限实测，尚未验证每帧差异、disposal 合成和最低系统 iOS/macOS 26。不能据此宣称动图阶段验收完成；未复制或修改参考素材。
