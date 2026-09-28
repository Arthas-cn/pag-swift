---
name: pag-swift-rewrite
description: >
  用 Swift 6.4 重写 libpag 时的仓库约束：公开 API 如何对照旧 PAG 类型、解码与渲染的隔离、
  .pag 必须以源码或官方文档为证据、库测试用 swift test。
  在改 PAG 文件、时间轴、图层、播放器、渲染表面、文本或图像替换、或把 C++/ObjC API 迁到 Swift 时使用。
  Use when implementing or designing the pag-swift library, PAG file decoding, playback, or rendering.
---

# PAG 的 Swift 重写

先读 `AGENTS.md`。本 skill 只补充库领域约束，不重复 R1–R11。

终态是 Swift 实现，不是给上游 C++ libpag 做永久包装，也不是把上游二进制当成运行时依赖。

## 仓库地图

| 路径 | 职责 |
| --- | --- |
| `packages/pag-swift` | 库。解码、场景图、时间轴、播放、渲染表面、替换 |
| `app/pag-swift-demo` | 验证集成的 SwiftUI demo，不是库本体 |

现状（以仓库为准，过时就改本段）：`Package.swift` 的 tools version 已是 6.4，并打开了 Approachable Concurrency。尚未声明 `platforms` 与 `swiftLanguageModes`。demo 工程仍可能是 Xcode 模板值（部署 27.0、`SWIFT_VERSION = 5.0`、默认 `MainActor`）。那些模板值**不是**基线；改到工程或包清单时对齐 `AGENTS.md` 技术栈。

改 `Package.swift` 时补上：

- `platforms`: iOS 26、macOS 26
- `swiftLanguageModes: [.v6]`（SPM 没有 `.v6_4`）
- 库 target 默认 isolation 为 `nonisolated`，不要为了 demo 把库标成 `@MainActor`

## 能力对照

设计 API 时先写「旧概念 → 本模块职责」，再起 Swift 名字。下表是职责，不是最终类型名。

| 旧公开概念 | 职责 |
| --- | --- |
| `PAGFile` | 从 `.pag` 字节或路径载入，得到可播放的合成 |
| `PAGComposition` / `PAGLayer` 及子类 | 场景图与时间轴上的图层（纯色、图像、文本、形状、预合成） |
| `PAGPlayer` | 把某一时刻的合成画到表面；持有当前时间与已提交帧的一致性 |
| `PAGSurface` | 渲染目标。必须能脱离视图单独使用 |
| `PAGView` | 平台宿主。iOS / macOS 的薄适配，不承载合成求值 |
| `PAGImage` / 文本数据 | 按可编辑索引或按名替换；不要另造一套与上游矛盾的键 |
| 时间 | 绝对时间是微秒。进度若用 `0...1`，必须和微秒在 API 上区分开 |

命名走 `swift-api-design-guidelines`。禁止把 ObjC 头文件逐符号译成 `get`/`set`、`initWith`，或因为旧 SDK 是 class 就把所有状态都做成引用类型。合并或拆分职责时，文档里写明，不要继续用旧名暗示一一对应。

内部解码器、渲染器、纹理所有权默认不要 `public`。

## 并发

- 库默认 `nonisolated`。解码、合成求值、离屏渲染、资源上传可以在后台做。
- 只有 UI 宿主（视图、图层挂载、跟窗口生命周期绑在一起的表面）明确走主 actor。
- 不要无同步地让多线程同时改同一棵图层树或同一块表面。
- 跨隔离优先传不可变快照或值。正在进行的解码或刷新必须能取消，迟到结果不得覆盖新的时间或替换。
- 具体隔离怎么标，读 `swift-concurrency-pro`，再落到类型上。不要把整个库套进 `@MainActor` 来让 demo 少写两行。

## 渲染

- 只承诺 iOS 26 与 macOS 26。可以用该系统的 Metal、Core Graphics、Core Video、SwiftUI。
- 不在规则里写死「必须 Metal」或「必须 Canvas」。选定实现时在该模块的注释或规范里说明理由。
- 播放器 + 表面必须能在没有视图时渲染。视图是宿主，不是渲染器本体。
- UIKit 与 AppKit 的差异留在适配层；时间轴和合成逻辑两边共用。

## `.pag` 证据

按字节解释文件时，证据只能是上游 [libpag](https://github.com/Tencent/libpag) 源码或 [pag.io](https://pag.io) 文档。注释或规范里写清路径、符号或段落。

没有证据：走失败路径或标成未实现。不要凭记忆写 tag、偏移或压缩细节。测试夹具用真实 `.pag`，或明确是「损坏输入」的用例；不要手写一段自称合法的假二进制。

## 测试

- 库：在 `packages/pag-swift` 用 `swift test`（Swift Testing）。
- demo 的安装、界面、真机或模拟器才用 `xcodebuild`，并先走 `ios-device-destination`。macOS 目标用 `platform=macOS`。
- 优先覆盖：加载成败、可见时间区间、进度与微秒不要混、替换后旧帧失效、播放器与表面的创建和释放。

## 动手前核对

- [ ] 这次改动是库、demo，还是两者的接入（R10）
- [ ] 公开名字对照了旧职责，并且读过 API 设计 skill
- [ ] 重活不在主 actor 上；表面与图层树的所有权写得清
- [ ] 任何字节级行为都有上游证据
- [ ] 库的验证命令是 `swift test`，不是只在 demo 里看一眼
