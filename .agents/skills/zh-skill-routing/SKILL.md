---
name: zh-skill-routing
description: >
  本仓库用户主要用中文交流。在中文提问或中英混写、涉及 PAG、libpag、动画、
  解码、渲染、时间轴、图层、公开 API、Swift、SwiftUI、并发、测试、SPM、
  模拟器、真机、xcodebuild destination 时使用。
  根据中文意图读取对应的英文或项目 skill，并用中文回复。
  Use when the user writes in Chinese about this PAG Swift rewrite.
---

# 中文对话 → Skill

第三方 skill 的 `description` 和正文是英文。中文对话时不要只凭训练数据写 Swift 或编造 `.pag` 布局，先按表读取对应 `SKILL.md`（及它指出的 `references/`）。

回复语言跟用户：默认中文。代码标识符保持英文。

## 路由表

| 用户中文意图（含近义说法） | 读取 |
| --- | --- |
| 重写 libpag、PAG 文件、时间轴、图层、播放、渲染表面、对照旧 PAG API | `.agents/skills/pag-swift-rewrite/SKILL.md`（必读） |
| 设计库模块、写实现规范、给另一个 Agent 写代码、只出文档先不实现 | `.agents/skills/component-spec/SKILL.md`（必读）+ `.agents/skills/swift-api-design-guidelines/SKILL.md` |
| 公开 API 命名、参数标签、调用点是否顺口 | `.agents/skills/swift-api-design-guidelines/SKILL.md` |
| 并发、async、await、actor、Sendable、渲染与解码的隔离 | `.agents/skills/swift-concurrency-pro/SKILL.md` |
| 单元测试、Swift Testing、`#expect`、`@Test` | `.agents/skills/swift-testing-pro/SKILL.md` |
| 新写或重构 demo 的 SwiftUI 界面 | `.agents/skills/swiftui-expert-skill/SKILL.md` |
| 审查 demo 的 SwiftUI：过时 API、无障碍、导航、性能 | `.agents/skills/swiftui-pro/SKILL.md` |
| 编译/测试选模拟器或真机、xcodebuild -destination | `.agents/skills/ios-device-destination/SKILL.md`（先跑其中脚本；仅 demo） |
| Xcode 编译慢、优化构建（先测再改，未批准不改工程） | `.agents/skills/xcode-build-orchestrator/SKILL.md` |
| SPM 依赖拖慢编译、包拆分、解析慢 | `.agents/skills/spm-build-analysis/SKILL.md` |

一次任务可读取多个。例如「给播放器定公开 API 并补测试」→ `pag-swift-rewrite` + API 设计 + Swift Testing。库测试能 `swift test` 则不要选设备。

## 不要做

- 不要改第三方 skill 的英文正文来「翻译」；更新会覆盖。
- 不要因为用户说中文就跳过读 skill。
- 本仓库没有安装 TCA、SwiftData、Keychain、axiom-testing；不要假装已装，也不要按那些架构写库。
