---
name: ios-device-destination
description: >
  编译、xcodebuild test、安装/启动 App、开模拟器前必须选用设备。优先有线已连接真机，
  没有可用真机才用已启动的模拟器；禁止每个 Agent 再 boot 一台模拟器。
  Use whenever running xcodebuild, launching the iOS Simulator, installing on a
  device, or choosing -destination. Do not pick name=iPhone 16 by habit.
---

# iOS 设备选择

本仓库最低部署 **iOS 26 / macOS 26**。`packages/pag-swift` 的测试在仓库根或包目录用 `swift test`，不要为了测库去选设备。本脚本只选 iOS destination；macOS 演示工程用 `-destination 'platform=macOS'`，不要套用本脚本的 iPhone 结果。

**其他 Agent 不要手写解析 `devicectl` 表格。** 只运行本 skill 的脚本，用它打印的 `xcodebuild_destination` / `udid` / `core_device_identifier`。

## 必须先跑脚本

仓库根目录：

```bash
python3 .agents/skills/ios-device-destination/scripts/select-ios-destination.py \
  --project app/pag-swift-demo/pag-swift-demo.xcodeproj \
  --scheme pag-swift-demo \
  --min-ios 26
```

成功时 stdout 只有 JSON（`ok: true`）。取字段：

| 字段 | 用途 |
| --- | --- |
| `xcodebuild_destination` | `xcodebuild … -destination '…'` |
| `udid` | 硬件 UDID；给 `xcodebuild` 的 `id=` |
| `core_device_identifier` | CoreDevice UUID；给 `xcrun devicectl … --device` |
| `kind` | `physical_wired` / `physical_network` / `simulator_booted` / `simulator_booted_after_boot` |

常用：

```bash
# 只要 destination 字符串
python3 .agents/skills/ios-device-destination/scripts/select-ios-destination.py \
  --project app/pag-swift-demo/pag-swift-demo.xcodeproj --scheme pag-swift-demo --print-destination

# 没有真机且没有已 boot 模拟器时，才允许 boot 一台（默认不允许）
python3 .agents/skills/ios-device-destination/scripts/select-ios-destination.py \
  --project app/pag-swift-demo/pag-swift-demo.xcodeproj --scheme pag-swift-demo --allow-boot
```

选完后报告：设备名、kind、udid、有没有 boot 模拟器。

## 优先级（脚本已实现）

1. 有线真机：`reality=physical`（或硬件 UDID 以 `0000` 开头）且 `transportType=wired` 且 `tunnelState=connected` 且已配对。
2. 当前隧道已连通的网络真机（`localNetwork` + `connected`）。未连通的「available (paired)」不算可用。
3. 已经 boot、且 OS ≥ `--min-ios` 的 iPhone 模拟器。
4. 仅当传入 `--allow-boot`：boot **一台** 已有的、OS ≥ min 的 iPhone 模拟器。禁止 `open -a Simulator`，禁止 `simctl create`，禁止再 boot 第二台。

多个 Agent 必须复用脚本给出的同一 destination。

## 两套 ID，不要混

人读的 `devicectl list devices` 表格里 Identifier 往往是**硬件 UDID**；JSON 的 `identifier` 是 **CoreDevice UUID**。只信脚本或 `--json-output` 文件。

- `xcodebuild -destination "platform=iOS,id=$UDID"` → 硬件 `udid`
- `xcrun devicectl device install/launch --device $CORE_ID` → `core_device_identifier`

只编译、不装机：`-destination 'generic/platform=iOS'` 可以，但仍不要顺手 boot 模拟器。

## 不要做

- 不要复制 axiom 示例：`-destination 'platform=iOS Simulator,name=iPhone 16'`（本仓库会撞上 iOS 18.6 模拟器）。
- 不要按设备名字猜；同名可对应多个 OS。
- 不要把表格里 `available (paired)` 当成已连接。
- 不要为每个对话 `simctl boot`。
- 不要把 CoreDevice UUID 和硬件 UDID 填反。

OS 低于部署目标的真机（`xcodebuild -showdestinations` 带 `error:`）脚本会跳过。

细节与 JSON 字段见 `references/device-ids.md`。
