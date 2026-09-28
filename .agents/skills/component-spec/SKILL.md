---
name: component-spec
description: >
  把用户描述的 PAG 库模块或 demo 能力写成完整、可交接的实现规范（中文为主），交给另一个 Agent 写代码。
  只出文档、不写实现，除非用户明确要求开始编码。适用于解码、时间轴、图层、渲染、播放、
  公开 API 合同、Agent 实现规范。
  Use when the user describes a package module and wants a design/spec for another agent
  to implement, not working source code.
---

# 模块实现规范（给另一个 Agent）

用户描述能力；本 skill 产出**实现合同**。默认**不写生产代码、不改 Package.swift 依赖、不提交**。用户明确说「开始实现」后再走 `AGENTS.md` R4。

规范读者是**零上下文的实现 Agent**：不能靠对话里没写进文档的默契。

## 工作流

1. 读 `Docs/核心实现.md` 与 `AGENTS.md`，并读 `.agents/skills/pag-swift-rewrite/SKILL.md`。新模块规范不得推翻其中的 Metal、SwiftUI / UIKit / AppKit 显示和技术基线。核心文档没有规定类型划分和公开签名。
2. 读用户描述。查原版行为时只读 `/Users/arthas/shibo/iOSProject/libpag`；查缓存、跑马灯、动图时只读 `/Users/arthas/shibo/iOSProject/VAPPlayerKit`。不要把这两个仓库的类型当成已在本仓库实现。
3. 缺会阻塞合同的信息时先问（边界、非目标、调用方、失败语义），不要用猜测填满公开 API，也不要凭记忆填 `.pag` 二进制布局。
4. 始终读取 `.agents/skills/swift-api-design-guidelines/SKILL.md`（及它指出的 `references/`），设计公开命名、参数标签与调用点。
5. 按模块再读领域 skill：并发读 `swift-concurrency-pro`；测试验收读 `swift-testing-pro`；包边界读 `spm-build-analysis`。demo 界面才读 SwiftUI skill。
6. 按 `references/spec-template.md` 写出完整规范；公开签名用 Swift 声明、**不要方法体**；标明「待实现合同，不是仓库里已有源码」。
7. 文档用中文；类型/方法/参数名用英文。规范里的公开签名用中文 `///`。实现阶段全部手写代码走 `AGENTS.md` R8。
8. 文末给「实现 Agent 启动提示」：先读哪份文档、禁止做什么、建议测试范围。

## 领域 skill（按需，可多份）

| 模块类型 | 读取 |
| --- | --- |
| 任何公开 Swift API | `swift-api-design-guidelines` + `pag-swift-rewrite` |
| 解码、时间轴、图层树、播放器、渲染表面 | `pag-swift-rewrite` + `swift-concurrency-pro` |
| demo 的 SwiftUI 宿主 | `swiftui-expert-skill` |
| 包怎么拆、依赖方向 | `spm-build-analysis` |
| 测试怎么写进验收 | `swift-testing-pro` |

第三方 skill 若与 `AGENTS.md` 冲突，**以本仓库技术栈为准**，在规范里写明取舍。

## 规范必须能让实现 Agent 独立开工

至少包含：

- 目标、非目标、库职责 vs demo 职责
- 模块/文件划分与依赖方向
- 公开类型与方法的签名、默认值、错误类型、Sendable/隔离
- 明确不暴露的内部类型（解码细节、渲染器、纹理所有权）
- 与旧 PAG 概念的对照（职责映射，不要求类型名逐字相同）
- 首版不做的能力
- 验收场景表（库用 `swift test`；不要把只能在 App 里点一下当成唯一验收）
- 文件格式相关条款：无上游证据的布局标成「未实现」，不要写成已定合同

## 不要做

- 不要把示意签名写成「已经存在的 SDK」。
- 不要为了显得完整而编造二进制字段、未讨论的平台或渲染器。
- 不要输出半份散文 + 「细节实现时再看」；含糊点标成「待用户确认」。
- 不要同时实现代码，除非用户明确要求。
- 不要在规范里另写一套注释规则；一律指向 `AGENTS.md` R8。
