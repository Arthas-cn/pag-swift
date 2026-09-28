# Agent 约定

本仓库日常用**中文**沟通。已安装的第三方 skill 正文是英文：用中文提问时，先按 `.agents/skills/zh-skill-routing/SKILL.md` 的路由表读取对应 skill，再用中文回答。

显式指定时，Cursor 用 `@skill名`，Codex 用 `$skill名`。安装与核对见 `Docs/agent-skills/README.md`。

后续重构与实现以 `Docs/核心实现.md` 为合同。改 PAG 解码、时间轴、图层、播放、渲染或公开 API 时：先读该文档，再读 `.agents/skills/pag-swift-rewrite/SKILL.md`。

只读参考，不要改这两个目录，也不要把它们加成编译依赖：

- 原版 libpag：`/Users/arthas/shibo/iOSProject/libpag`
- VAPPlayerKit（缓存、跑马灯、动图占位的设计参考）：`/Users/arthas/shibo/iOSProject/VAPPlayerKit`

用户只描述模块能力、要完整实现文档、交给另一个 Agent 写代码时：走 `component-spec`，并读取 `swift-api-design-guidelines` 与 `pag-swift-rewrite`。默认只出规范、不写实现。

`xcodebuild`、安装 demo、启动模拟器或选择 `-destination` 前：走 `ios-device-destination`，先跑其脚本。库测试能 `swift test` 则不要选设备。

## 技术栈

- 语言：Swift 6.4（Xcode 27 自带编译器）。工程写 `SWIFT_VERSION = 6.4`；Xcode 会映射为语言模式 Swift 6（`EFFECTIVE_SWIFT_VERSION = 6`）。按严格并发来写，并使用 Swift 6.4 语法。不要改回 `6.0` 或 5。库与 demo 都开启 Approachable Concurrency。**库的默认 actor isolation 为 `nonisolated`。**
- 平台：iOS 26.0 与 macOS 26.0 为最低部署版本。可以放心使用这两个系统的 26 API；不要为更早系统加 `#available` 回退或旧架构兼容层，除非任务明确要求。不要在没有任务时把包或工程扩到 watchOS、tvOS、visionOS。
- 目标：用 Swift **重写** libpag（PAG 矢量动画），不是给上游 C++ 库做永久包装。库在 `packages/pag-swift`；`app/pag-swift-demo` 只验证集成。
- `Docs/核心实现.md` 只写技术基线、核心功能和背景，不规定类型划分和公开签名。架构由后续文档决定。对照旧 `PAG*` 只用于核对职责。禁止把 ObjC 头文件机械翻译成 Swift。
- 渲染：Metal，直接画到显示目标。播放优先，热路径不要先离屏再拷贝，也不要为播放把像素读回 CPU。不要移植原版的 OpenGL / CGL。离屏出图不是必须能力。
- 界面：SwiftUI、UIKit，以及 macOS 的 AppKit 都要能播。demo 用库的显示能力做验证，不在 App 里另写一套播放器。
- 包：SPM。`swift-tools-version` 最低 6.4；语言模式用 `swiftLanguageModes: [.v6]`（SPM 没有 `.v6_4`）。`platforms` 声明 iOS 26 与 macOS 26。不要把 tools version 改低，也不要把语言模式改成 `.v5`。
- demo 工程的部署与语言版本以 target 为准：`IPHONEOS_DEPLOYMENT_TARGET = 26.0`，`MACOSX_DEPLOYMENT_TARGET = 26.0`，`SWIFT_VERSION = 6.4`。Xcode 模板里的部署版本 27.0 和 `SWIFT_VERSION = 5.0` **不是**基线。demo 的 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 可以保留，因为界面在主 actor 上。库 target 必须是默认 `nonisolated`，不要为了少写派发把库标成 `@MainActor`。

以下 R1–R3、R8–R9 始终遵守。R4–R7、R10–R11 按用户意图套用，不必用户重贴模板。并发、测试、SwiftUI、API 命名、构建优化的细节读对应 skill，不在本文件复述。

## R1 改动边界

- 只改完成当前任务所需的代码，不顺手重构、不改无关行为。
- 沿用仓库现有模块划分、命名和模式（`app/`、`packages/`）。目录是小写，不要改成 `Apps/` 或 `Packages/`。
- 不引入任务未要求的依赖或新框架。终态不要把上游 libpag 二进制加进来当运行时依赖。
- 不编造仓库里不存在的类型、API、文件或配置。不凭记忆编造 `.pag` 二进制布局。
- 未要求时不改工程配置、不提交 git、不推远程。

## R2 动手前与交付后

动手前（实现类任务，简短即可）：

1. 用一两句话复述需求。
2. 标出缺失或含糊的点；会阻塞实现时先问，不猜着写。
3. 说明计划改哪些文件 / 模块。

交付后：

1. 说明实际改了什么、为什么。
2. 给出如何验证（库用 `swift test`；demo 才用编译、安装或手动步骤）。
3. 列出未做事项或已知风险。
4. 对照 R8：声明有 `///`，关键分支有 `//`，每个测试用例说明测的场景。缺注释不算完成。

## R3 证据与不确定性

- 区分：仓库里能看到的事实、上游 libpag 源码或 pag.io 文档能证实的事实、合理推断、尚未验证的假设。
- 做不到的事先说，不把猜测写成已证实。字节级行为没有证据就不要实现成「先能跑」。
- 引用代码时指向具体文件与符号，不空泛说「某处」。

## R4 实现功能

用户要写或改功能时：

1. 复述需求 → 含糊点 → 受影响模块 → 最小可维护方案。
2. 再改代码；重要设计选择用一两句说明。
3. 补上与改动匹配的测试（库沿用 Swift Testing）。
4. 点出边界情况，并给简短验证清单。
5. 约束同 R1：不扩依赖、不改无关行为。
6. 新写或改到的 Swift 遵守 R8（中文注释）和 R9（文件体量）；没有按 R8 写注释不得声称实现完成。

动库之前先读 `pag-swift-rewrite`。公开 API 再读 `swift-api-design-guidelines`。并发读 `swift-concurrency-pro`。测试读 `swift-testing-pro`。demo 界面才读 SwiftUI skill。

## R5 调试

用户报 bug、崩溃或异常行为时：

1. 先列最可能原因，按概率排序，并写清每条依据（日志、代码、复现）。
2. 给出验证或排除假设的最快方法。
3. 再给最小、安全的修复；说明副作用。
4. 建议回归点。
5. 不要一上来重写整段实现。

## R6 代码审查

用户要 review 时，按项评估：正确性、安全性、性能、可维护性（含 R8 注释、R9 体量）、错误处理、测试、边界情况。方法无 `///`、关键分支无 `//` 按可维护性列出，不要只检查公开 API。

每个问题写：严重度（严重 / 高 / 中 / 低）、为何重要、最小改法。

最后给：优先改的最多三项、已经做得好的地方、可能的架构风险。

不为风格而建议大重构。库的行为与格式证据走 `pag-swift-rewrite`，并发走 `swift-concurrency-pro`，测试走 `swift-testing-pro`。demo 的 SwiftUI 审查走 `swiftui-pro`。

## R7 理解代码库

用户要摸结构、问从哪读起时：

先说清：整体结构、主要目录职责、入口、从文件到画面的数据流、包依赖、平台适配放在哪、测试怎么组织。

然后：一条典型播放路径如何走完；建议先读的最多五个文件；哪些区域复杂或风险高。

按「刚进组的开发者」来写，不假设读者已经熟悉本仓库或 libpag 的 C++ 实现。

## R8 中文注释

新写或改到的手写代码必须让**没参与实现的人**读懂职责和关键取舍。缺注释视为未完成。不为凑规则给无关文件刷注释（仍守 R1）。

本规则对库、demo、测试通用。**不要按模块再写一套注释细则。**

**语言**

- 注释以中文为主。类型名、属性名、方法名、API 名保持英文。
- 专有名词可夹英文：`Sendable`、`PAGFile`、Apple API。
- 非 Swift 的手写代码同样用中文写清职责与非显然分支，不另起规则。

**声明上必须用 `///`（访问级别不豁免）**

`internal` / `private` / `fileprivate` 与 `public` / `package` 同等要求。第三方 skill 若只要求公开 API 文档，仍以本条为准。

1. 每个 `class` / `struct` / `enum` / `actor` / `protocol`，以及承担独立职责的 `extension`：做什么、不做什么、属于哪一层。
2. 每个存储属性：业务含义、合法范围或 `nil` 含义；不要只复述标识符。
3. 每个 `enum` case（含关联值）：何时选这一支、和相邻 case 有何差别、关联值是什么。不要用「名字已经够清楚」跳过；也不要把多个未注释的 case 挤在同一行。
4. 每个方法、初始化器、下标：做什么、关键参数与返回值、失败或取消时抛什么/返回什么、重要前置条件。一行实现也要有 `///`。协议已用 `///` 说明、空默认实现可不再重复。
5. 改已有声明时同步改注释，禁止留下与行为相反的旧注释。

**方法体内必须用 `//` 写清非显然步骤**

写在步骤**之前**，说明**为什么这样写**或**必须遵守的约束**，不要复述下一行代码在做什么。

判断标准：换一个没写过这段代码的人，只看标识符和类型，仍会问「为什么走这条路 / 为什么在这里停 / 为什么故意不做某件事」，就必须写 `//`。

需要写的是通用情况，例如：

- 类型表达不了的不变量：顺序、互斥、只生效一次、迟到结果必须丢掉
- 并发：隔离、可重入、暂停点前后状态、谁负责结束未完成的工作
- 失败：为何转成另一种错误、为何吞掉、为何让调用方自己停
- 故意不走某条路：跳过、提前结束、忽略某个输入
- 看起来像笔误、其实是有意为之的默认值或分支

不必写：顺向赋值、普通遍历、`guard let` 解包成功后的直接使用。

**示例**

```swift
/// 缓冲满时如何处理新记录。
enum OverflowPolicy {
    /// 丢掉最旧记录，给新记录腾位置。
    case dropOldest
    /// 拒绝新记录，已有内容保持不变。
    case rejectNewest
}

/// 只接受与当前提交序号相符的结果；过期完成必须丢弃。
func finish(_ result: Result<Value, Error>, sequence: Int) {
    // 序号对不上：这是上一轮提交的迟到结果，写进去会覆盖新值。
    guard sequence == currentSequence else { return }
    storage = result
}
```

**不要写**

- 复述标识符：`/// 用户名` 对着 `var username`，或 `/// 成功` 对着 `case success`。
- 给 `import`、纯布局（`VStack` / `padding`）、显而易见的赋值逐行加注。
- 在源码 `///` 里写 DocC 的 `## Overview` / `## Topics`。
- 用注释代替清晰命名或拆函数。
- 用「internal 不用写」「一行函数不用写」「只有复杂算法才写」「测试方法名已经是文档」缩小本规则。

**测试与配置**

- 测试类型头说明这一组覆盖哪类行为。
- 每个测试用例（`@Test`、`func test…` 等）必须有 `///`：写清测的是什么行为或场景、期望看到什么结果。不能只靠方法名或 `@Test("…")` 显示名。参数化测试写清这一组输入共同验证什么；不要给每个参数再发明一套规则。

```swift
/// 缓冲已满时再写入，应丢掉最旧记录并留下新记录。
@Test func appendDropsOldestWhenFull() { ... }
```

- 测试体内的 `#expect` / 断言不必逐条加注；准备数据或步骤有非显然约定时用 `//`。
- 测试辅助类型/方法若有非显然约定，仍要 `///`。
- `Package.swift`、工程配置：只注释非显然的自定义设置。

## R9 单文件体量

对手写 Swift 计全部行数（含空行与注释）。**禁止删注释凑行数。** 超限先拆文件；禁止靠省略注释、或把多步挤成一行来规避 `//`。

| 文件 | 尽可能（软限制） | 硬限制 |
| --- | --- | --- |
| 生产代码（`app/` / `packages/` 源码） | 700 行 | 1200 行 |
| 测试代码（`*Tests.swift` 等） | 1000 行 | 1200 行 |

- 生产代码接近 600 行、测试接近 900 行时，按职责开拆，不要堆到软限制再拆。
- 达到硬限制必须先拆再继续写；交付时若已过软限制，说明原因和下一步拆法。

**本仓库优先拆法**

| 场景 | 怎么拆 |
| --- | --- |
| 场景图 / 时间轴 | 合成、图层、播放器分文件 |
| 解码 | 按阶段分文件；不要把格式证据注释删掉来省行数 |
| 渲染 | 表面与平台宿主分开；合成求值不要写进 SwiftUI `View` |
| 测试 | 按场景拆 `*Tests.swift`，文件内用 `// MARK: -` |

**例外（不计入上述限制）**

- 生成代码、`project.pbxproj`、第三方源码
- 拆开会破坏完整性的单条巨型字面量（应尽量避免这种数据进源码）

**不要**

- 在函数中间把文件切断
- 为了行数引入无意义的空壳类型
- 把 SPM 模块拆成大量无职责边界的小文件（模块文件数过多会扩大增量编译范围，与单文件行数不是一回事）

## R10 将本地 SPM 包接入 demo

1. 确认 `packages/.../Package.swift` 声明了要使用的 library product，名称与工程中的 product 名一致。
2. 将本地包及其 product 加入实际使用它的 target（当前是 `app/pag-swift-demo`）。不能仅凭包文件夹出现在工程中，或仅新增 product 名称，就认为接入完成。
3. 对每个使用该 product 的 target，检查其 `packageProductDependencies` 和 `Frameworks` 构建阶段均有对应引用。本地包路径必须是相对仓库的路径，不能提交只在本机绝对路径上可解析的引用。
4. 若 demo 源码目录是文件系统同步文件夹，检查包源码没有被直接纳入 App target 编译。
5. 修改后检查工程文件语法、Xcode 的包解析，以及受影响 target 的构建。

## R11 创建本地 SPM 包

1. 按模块职责确定包名和 `packages/` 下的位置，确认目标目录尚不存在。
2. 在新目录中运行 `swift package init`。以 library 包为例，从仓库根目录执行：

   ```sh
   mkdir -p packages/ExampleModule
   cd packages/ExampleModule
   swift package init --type library --name ExampleModule --enable-swift-testing --disable-xctest
   ```

3. 不得手写或用脚本拼接初始 `Package.swift`、`Sources`、`Tests` 骨架。需要其他包类型时，使用 `swift package init --help` 确认并选择对应的 `--type`。
4. 生成后按仓库要求调整清单：核对 `swift-tools-version: 6.4`、`platforms`（iOS 26 与 macOS 26）、product 与 target，并设置 `swiftLanguageModes: [.v6]`。将占位源码和测试替换为实际内容，遵守 R8。
5. 运行 `swift package dump-package` 检查清单；适合在当前主机执行测试的包再运行 `swift test`。需要供 demo 使用时，按 R10 接入实际使用它的 target。
