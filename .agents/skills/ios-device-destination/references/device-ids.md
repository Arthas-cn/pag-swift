# 设备 JSON 字段（Xcode 27 / CoreDevice）

`xcrun devicectl list devices --json-output FILE` 的 `result.devices[]`：

| 路径 | 含义 |
| --- | --- |
| `identifier` | CoreDevice UUID，给 `devicectl --device` |
| `deviceProperties.name` | 显示名 |
| `hardwareProperties.udid` | 硬件 UDID，给 `xcodebuild -destination id=` |
| `hardwareProperties.reality` | `physical` / `simulated`；部分离线真机可能缺省 |
| `hardwareProperties.platform` | 真机多为 `iOS` |
| `hardwareProperties.productType` | 如 `iPhone13,2` |
| `connectionProperties.transportType` | `wired` / `localNetwork` / `sameMachine`（模拟器） |
| `connectionProperties.tunnelState` | `connected` / `disconnected` / `unavailable` |
| `connectionProperties.pairingState` | 真机应为 `paired` |

USB 旁证：`ioreg -p IOUSB -w 0` 中 iPhone 的 `USB Serial Number` 去横线后等于硬件 UDID 去横线。

`xcrun xctrace list devices` 的 `== Devices ==` 段是当前在线真机（含 OS 版本）；`== Devices Offline ==` 不要拿来跑测试。

`xcodebuild -showdestinations` 里带 `error:` 的行（部署版本不够等）不可用。
