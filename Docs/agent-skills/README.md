# Agent Skills 安装与核对

本目录记录本仓库已安装的 Swift Agent Skills。项目是用 Swift 6.4 重写 libpag，最低系统 iOS 26 与 macOS 26。规则正文在仓库根目录 `AGENTS.md`。

- **安装范围**：本仓库项目级（随 git 共享），不是个人全局安装。
- **目标 Agent**：Cursor、Codex（ChatGPT / Codex CLI）。
- **实际落盘路径**：`.agents/skills/`（Cursor 与 Codex 的项目级共用目录，**必须提交进 git**）。
- **版本锁定文件**：仓库根目录 `skills-lock.json`（必须提交）。
- **来源**：第三方 skill 与 `base_ios` 锁定的同一份副本。本仓库没有安装 TCA、SwiftData、Keychain、axiom-testing，避免把库写成 App 架构。

`.gitignore` **不忽略 skills**。被忽略的只有 `.cursor/settings.json`。

## 已安装清单

| Skill | 作用 | 本仓库路径 |
| --- | --- | --- |
| `swift-concurrency-pro` | 审查 Swift 并发 | `.agents/skills/swift-concurrency-pro/` |
| `swift-testing-pro` | 编写 / 审查 Swift Testing | `.agents/skills/swift-testing-pro/` |
| `swift-api-design-guidelines` | 公开 API 命名与调用点 | `.agents/skills/swift-api-design-guidelines/` |
| `swiftui-expert-skill` | 编写 demo 的 SwiftUI | `.agents/skills/swiftui-expert-skill/` |
| `swiftui-pro` | 审查 demo 的 SwiftUI | `.agents/skills/swiftui-pro/` |
| `spm-build-analysis` | 分析 SPM 对编译时间的影响 | `.agents/skills/spm-build-analysis/` |
| `xcode-build-orchestrator` | Xcode 构建优化入口：先基准再建议 | `.agents/skills/xcode-build-orchestrator/` |

来源仓库与安装命令以 `base_ios` 的 `Docs/agent-skills/README.md` 为准，但**只装上表这 7 个**，并且必须带 `--skill`。不要整包安装 `axiom`、`johnrogers/claude-swift-engineering`、`dpearson2699/swift-ios-skills`。

第三方 skill 正文可能仍写 “Swift 6.2 or later”。以 `AGENTS.md` 的 Swift 6.4、iOS 26、macOS 26 为准。

## 本仓库自建

不通过 `npx skills add` 安装，也不写入 `skills-lock.json`：

| Skill | 作用 |
| --- | --- |
| `zh-skill-routing` | 中文意图路由到上表与自建 skill |
| `pag-swift-rewrite` | PAG 重写的领域约束：API 对照、隔离、`.pag` 证据、测试分工 |
| `component-spec` | 模块功能 → 给实现 Agent 的规范，默认不写代码 |
| `ios-device-destination` | demo 选 iOS destination；库测试不要用它 |

## 为什么 SwiftUI 装了两个

| | `swiftui-expert-skill` | `swiftui-pro` |
| --- | --- | --- |
| 定位 | **写** demo 界面 | **审查** demo 界面 |
| 不负责 | 库的解码、时间轴、渲染 | 同上 |

库的实现不要因为装了 SwiftUI skill 就把播放器写成 `View`。

## 目录约定

```text
libpag-swift/
  AGENTS.md
  .agents/skills/          # 实际加载的 skill（必须入库）
  .cursor/skills           # 指向 ../.agents/skills 的符号链接（必须入库）
  skills-lock.json         # 仅 7 个第三方 skill
  Docs/agent-skills/       # 本说明
  .cursor/settings.json    # 仅本地编辑器配置（忽略）
```

## 核对

```bash
test -f .agents/skills/swift-concurrency-pro/SKILL.md && \
test -f .agents/skills/swift-testing-pro/SKILL.md && \
test -f .agents/skills/swift-api-design-guidelines/SKILL.md && \
test -f .agents/skills/swiftui-expert-skill/SKILL.md && \
test -f .agents/skills/swiftui-pro/SKILL.md && \
test -f .agents/skills/spm-build-analysis/SKILL.md && \
test -f .agents/skills/xcode-build-orchestrator/SKILL.md && \
test -f .agents/skills/zh-skill-routing/SKILL.md && \
test -f .agents/skills/pag-swift-rewrite/SKILL.md && \
test -f .agents/skills/component-spec/SKILL.md && \
test -f .agents/skills/ios-device-destination/scripts/select-ios-destination.py && \
test -L .cursor/skills && \
test -f skills-lock.json && \
test ! -d .agents/skills/composable-architecture && \
test ! -d .agents/skills/swiftdata-pro && \
test ! -d .agents/skills/swift-security-expert && \
test ! -d .agents/skills/axiom-testing && echo "OK"
```

## 使用方式

| 环境 | 显式调用示例 |
| --- | --- |
| Cursor | `@pag-swift-rewrite`、`@component-spec`、`@ios-device-destination` |
| Codex | `$pag-swift-rewrite` 等，名称与目录名一致 |

中文对话先命中 `zh-skill-routing`，再读英文 skill。不要翻译第三方 skill 正文。

## 不要做的事

- 不要把 `.agents/` 或 `skills/` 写进 `.gitignore`。
- 不要加 `-g` 装到用户目录。
- 不要补装 `composable-architecture`、`swiftdata-pro`、`swift-security-expert`、`axiom-testing`。
- 不要对来源仓库省略 `--skill`。
