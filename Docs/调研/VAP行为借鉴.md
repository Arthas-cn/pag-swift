# VAPPlayerKit 行为借鉴与排除项

> 2026-09-28，只读源码调研。本文提供架构设计的证据，不是 PAG 文件格式说明，也不表示相关类型已经存在于 `pag_swift`。
>
> 本地参考根目录：`/Users/arthas/shibo/iOSProject/VAPPlayerKit`。下文的参考路径均相对于此目录。没有修改参考仓库，没有执行其测试。

## 1. 结论与范围

可以借鉴：按文件身份复用解析结果、合并同一次并发加载、清理后禁止迟到写回、播放任务代数、有限帧缓冲与背压、跑马灯独立累计时钟、空槽位不阻断播放、动态图片暂停/恢复，以及直接向 Metal drawable 提交的显示路径。

不能直接搬入 PAG：VAP 的 MP4/vapc 格式、分屏 RGB/alpha、`AVAssetReader` 主播放管线、UIKit 专用图像与文本栅格化、Swift 5.9 / iOS 15 基线、SDWebImage 运行时探测、音频播放职责，以及它的 `PlayerView` / `PlaybackSession` 类型划分。

尤其需要区分两项事实：

- VAPPlayerKit 本体没有自行解码 GIF / 动画 WebP；它接收宿主准备的 `SDAnimatedImage`，通过运行时桥获取和调度帧。示例另行依赖并注册 `SDWebImageWebPCoder`。这不能作为 ImageIO 原生动画 WebP 可用的证据。
- VAPPlayerKit 的 Metal 主路径直接画入 drawable；没有把整帧先画到离屏纹理再拷屏。文本或图片的预生成纹理是输入资源，不是整帧离屏输出。

对应 `Docs/核心实现.md`：借鉴的是缓存、跑马灯、占位/动态图的用户可感知行为；本仓库必须重新建立 Swift 6.4、iOS 26/macOS 26、严格并发、SwiftUI/UIKit/AppKit 共用的实现。

## 2. 文件身份、缓存与加载合并

### 2.1 源码中已确认的行为

| 行为 | 证据路径与符号 |
| --- | --- |
| 进程内共享解析结果，不缓存解码帧、解码器和 GPU 资源 | `Sources/VAPPlayerKit/Public/AssetMetadataCache.swift`，`AssetMetadataCache`、`cache`、`Resolution` |
| 缓存键来自规范化本地 URL，另区分解析模式 | 同文件，`key(for:assetMode:)`、`cacheAssetModes` |
| 命中后校验文件 identity、大小和修改时间，签名不全则拒绝复用 | 同文件，`validateReusableFileSignature(_:for:)`（约 313 行） |
| 相同键和相同代数上的并发 miss 共享一条 Task | 同文件，`resolve(url:inspector:assetMode:)`（约 176 行）、`makeFlight(for:url:inspector:assetMode:)`（约 226 行）、`InFlight` |
| 全局清空、禁用、单 URL 移除都会使相应旧写入失效 | 同文件，`Generation`、`removeAll()`、`countLimit`、`remove(url:)`、`storeIfCurrent`（约 359 行） |
| 删除陈旧对象前再次确认缓存仍是该实例，避免误删后来写入的新值 | 同文件，`removeIfCurrent(_:for:assetMode:)` |
| 并发任务完成后移除 in-flight，剩余任务为空时清理 URL 代数 | 同文件，`finish(key:flight:)`（约 377 行） |
| 复用元数据时跨准备阶段再次验签，防 inspection 与解码器打开之间替换文件 | `Sources/VAPPlayerKit/Internal/PlaybackSession.swift`，`prepare(using:)`；在解码轨准备后、动态内容和音频准备后均有验证 |

`countLimit == 0` 在该库表示禁用缓存，不能直接透传 `NSCache.countLimit == 0`，因为后者表示没有数量限制。这是可借鉴的公开语义与底层容器语义分离；默认数量 20 只是参考库的选择，不应无依据成为 PAG 的默认容量。

文件签名只证明被检查到的 identity / 大小 / 修改时间匹配，不是文件内容加密校验，也不是读取期间文件不变的绝对保证。PAG 架构需要自己定义读取前后验签和稳定字节快照；内存 `Data` 没有文件 identity，不应假装可以复用路径缓存键。

### 2.2 对 PAG 架构的建议合同

以下是建议，不是 VAP 源码已有 API：

1. 全局共享不可变的已解析 PAG 文档；每个播放器独立持有替换、时间、播放状态和渲染资源。
2. 文件加载的稳定身份包含规范化文件地址与可取得的文件签名。读前/读后变化时不得把混合或陈旧结果写入缓存。
3. 同一有效身份的一次解析可服务多个等待者。取消某个等待者只能结束它的等待，不能无条件取消其他等待者仍依赖的共享解析；最后一个等待者退出时可取消底层工作。
4. 对缓存删除与禁用增加代数；解析完成后必须同时核对输入身份、缓存代数和本次任务身份。不要让旧任务清理新任务的 in-flight 表项。
5. 缓存容量及字节成本有界；不以全帧预渲染、持久化帧缓存、GPU readback 来换取所谓命中速度。
6. 解码错误不缓存成成功结果。已有播放器可继续使用其不可变快照；缓存失效不应悄悄修改正在播放的图层树。

VAP 的 `NSLock + Task` 是参考实现，不能据此宣称它的类和 UIKit 对象符合 Swift 6 严格 `Sendable`。PAG 可以用 actor 管理缓存与 in-flight 状态，后台解析任务传递不可变值，具体方案由架构合同明确。

## 3. 取消与迟到结果

VAP 有多层失效判定，而不是仅调用一次 `Task.cancel()`：

- `Public/PlayerView.swift` 的 `beginNewOperation()`（约 379 行）递增 `operationGeneration` 并取消上一条 `playTask`；`prepareInternal`（约 145 行）在 `await` 后同时核对操作代数和当前 session token，避免旧准备覆盖新播放。
- `Internal/DynamicResolver.swift` 的 `resolve` / `cancel` 维护解析代数；`resolveOne` 在 provider 返回后和 `materialize` 暂停点后复核代数。
- 同文件的 `DynamicResolutionGate.finish`（约 481 行）用锁保证 provider、取消、超时、重复回调只有一个结果能恢复 continuation。
- `Internal/AnimatedDynamicPlayback.swift` 的 `stop()` 递增 `generation`；帧回调先比较代数再替换纹理。
- `Internal/PlaybackSession.swift` 的 `tick()`（约 467 行）在 GPU 回调回到状态机时同时比较 token、`renderGeneration` 和 `terminalDelivered`，迟到 GPU 完成不会改写新状态；`fail` 与 `deliverFinish` 用终态标志确保结束事件互斥且至多一次。
- `Internal/FrameRingBuffer.swift` 的 `cancelWaiting()` 唤醒正在等待容量的 producer。仅丢弃 task 引用不足以解除满缓冲阻塞。

对 PAG 应保留的约束是：每次载入、seek、替换和显示目标变更都有可验证版本；CPU 求值完成后、申请 drawable / 提交 GPU 前、GPU 完成回报时都检查当前性。已经提交 GPU 的命令无法靠 Swift Task 取消撤销，必须保留资源到完成，再忽略过期完成事件；不能把“丢弃回调”描述为“已经提交的旧像素绝不显示”。

## 4. 跑马灯

### 4.1 源码中已确认的行为

`Internal/DynamicResolver.swift` 的 `resolveText`（约 240 行）先测量单行宽度：

- 放得下：静态栅格图，不启动跑马灯。
- 溢出且选择 marquee：尝试生成 `[文字][间隙][文字]` 的长条纹理。
- 长条超过纹理预算：生成截断文本，避免超大分配。

`Internal/MarqueeDynamicPlayback.swift` 中：

- `MarqueeLayout.offset` 是时间到偏移的纯函数；每轮先停顿，再按恒速滑动，按滚动自身周期取余。
- `start()`（约 123 行）仅从 paused 恢复，不因视频循环重复调用而归零；`pause()` 冻结累计 elapsed；`stop()` 清空槽位和时钟。
- `resetClock()` 只在全新播放开始时调用；`PlaybackSession.completeLoop()` 重置视频时钟时不会重置跑马灯时钟。
- `notePresented`（约 151 行）等到包含该文本槽位的帧呈现路径成功后才锁存起始时间，避免预加载/GPU 等待消耗起步停顿。源码的调用点在 command buffer 完成回报之后，因此这是该库对“成功上屏”的近似语义，不是单独的屏幕扫描呈现证明。
- `apply()` 只更新 source UV；滚动每帧不重新排版或重新生成文字 bitmap。

`DynamicTextureLimits.swift` 对单图、session 总量、维度和乘法溢出做分配前检查。64 MiB / 128 MiB / 8192 是 VAP 的取值，PAG 不应原样接受为跨设备预算。

### 4.2 对 PAG 架构的建议合同

跑马灯是替换文本的显示策略，不新增 `.pag` 字段。共享合成时间仍负责图层出现/消失；跑马灯另存累计激活播放时间：PAG 循环不回零，pause/suspend 冻结，恢复继续，stop 或新的替换版本按合同重置。架构必须明确 seek 是否重置跑马灯，不能由实现者猜测。

建议在替换或文字样式变化时测量/栅格化一次，播放热路径只算偏移与更新绘制参数。PAG 需要使用可在后台工作的跨平台文本布局/字形方案，不能照搬 VAP 在 `@MainActor materialize` 中用 UIKit 绘制的实现。

## 5. 静图、占位图、GIF 与动画 WebP

### 5.1 占位与空槽位

参考库的“占位”主要是宿主示例策略，不是本体内置的独立占位状态机：

- `Examples/SwiftExample/SwiftExample/GiftCatalog.swift` 的 `content(for:imagePolicy:imageIndex:replacementIndex:)` 在找不到图片时调用 `placeholder(size:tag:)`，生成普通 `UIImage`。
- `Internal/DynamicResolver.resolve` 在没有 provider 时为所有槽位生成 `.hidden`；provider 返回 nil 也映射 `.hidden`。
- `Internal/MetalRenderer.encode` 的动态附件遍历遇到没有纹理的槽位直接跳过；其余视频内容继续提交。

PAG 需要明确自己的占位选择与替换状态：占位可以是静图或由库解码的动画图，缺少占位时空槽位不阻止其他图层播放。图片解码失败应返回可识别错误，是否继续显示原图或占位由架构预先约定；不能把任意错误静默当成“没有输入”。

### 5.2 动图实现的真实边界

| 已确认行为 | 证据 |
| --- | --- |
| 普通 `UIImage` 即使请求 animated 仍按静图处理 | `Internal/DynamicResolver.swift`，`resolveImage`（约 213 行） |
| 多帧判定只识别运行时可用的 `SDAnimatedImage`，且 frameCount > 1 | `Internal/SDWebImageRuntime.swift`，`isAvailable`、`isAnimatedImage`、`frameCount` |
| 准备阶段取第一帧，开始后逐帧更新纹理，暂停保留 player，结束释放 | `Internal/AnimatedDynamicPlayback.swift`，`prepare`、`start`、`pause`、`stop`、`apply` |
| 动图循环跟随 session 生命周期，无限循环值设为 0 | `Internal/SDWebImageRuntime.swift`，`makePlayer(provider:onFrame:)` |
| 示例的 GIF/WebP 优先交给 SDAnimatedImage | `Examples/SwiftExample/SwiftExample/GiftCatalog.swift`，`image(at:)`（约 187 行） |
| 示例注册 WebP coder，ImageIO 回退只取第 0 帧 | 同文件，`webPCoderRegistration`、`image(at:)`；工程显式依赖 SDWebImageWebPCoder |

因此，不能引用这个仓库证明“ImageIO 一定能解动画 WebP”。本项目应自行提供图片字节/文件输入与内部帧源，不探测 SDWebImage 类，不把第三方 provider 混进公开 API。

动画 WebP 的验收必须针对 iOS 26 与 macOS 26 的实际系统能力：至少验证帧数、每帧时长、多帧解码与最终合成效果；不能仅凭扩展名或能解第 0 帧宣称动画支持。系统能力不足或仍未验证时，返回明确 unsupported 错误，记录能力状态，不把静态首帧冒充动画成功。GIF 同样需要验证帧时序和画布合成语义。

本轮父 Agent 的有限实测补充：在当前 macOS 27 上用临时 Swift/ImageIO 探针读取参考样例，`earth.gif` 返回 250 帧、512×384，首末帧可解，所读帧时长为 0.02 秒；`webp01.webp` 返回 10 帧、387×217，首末帧可解，所读 `WebPUnclampedDelayTime` 为 0.2 秒。该结果支持“当前主机上存在可继续验证的系统解码路径”，不证明全部帧的合成/处置语义正确，也不证明 iOS 26/macOS 26 均支持；不得据此取消真实动图的逐帧、像素和时序验收门禁。

### 5.3 推荐性能约束

- 静图只有一帧，不建立常驻帧调度器。
- 多帧资源采用有界预读与纹理复用，不把全部动图帧无上限解码入内存。
- 主线程只更新视图生命周期和轻量控制快照；字节读取、图片解码、尺寸转换与纹理上传在后台所有者内完成。
- 新替换建立新的资源版本；旧动图的异步帧回调不能写进新槽位。

## 6. Metal 直接显示路径

`Public/PlayerView.configureLayer()` 创建独立 `CAMetalLayer`，配置透明背景、`.bgra8Unorm`、`framebufferOnly = true`。`layoutSubviews()` 更新点到像素的 drawable 尺寸，并在零尺寸时挂起。

`Internal/MetalRenderer.render` 把工作提交到专用 `renderQueue`；`encode`（约 304 行）的关键路径是：

1. 从显示层取得 `nextDrawable()`。
2. 把 `MTLRenderPassDescriptor.colorAttachments[0].texture` 直接设为 `drawable.texture`（约 340 行）。
3. 在这个 render pass 画底图和动态槽位。
4. `endEncoding()` 后 `commandBuffer.present(drawable)`（约 401 行）。

没有整帧离屏目标、整帧 blit-to-screen 或 CPU 像素读回。输入 CVPixelBuffer 通过 CVMetalTexture 包装后采样；这属于视频输入纹理，不是输出读回。`InFlightFrameResources` 保留输入缓冲与 CVMetalTexture 到 GPU 完成，防止提前释放。

`PlaybackSession.tick` 在 `renderPending` 为真时跳过 tick，避免堆积 command buffer；`FrameRingBuffer.dequeueDue` 消费到期帧但只交付最新一帧；drawable 暂不可用返回 `false`，保留待提交帧重试而不是立刻作为播放终态。可以借鉴这些有界排队和临时不可用语义，具体容量由 PAG 渲染负载验证。

PAG 必须共用一套 renderer 和时间求值，让 SwiftUI、UIKit、AppKit 只承担宿主差异。显示目标本身可独立于视图管理，但这不意味着需要实现离屏输出 API。不要新增 MakeOffscreen、截图、像素读回合同。

## 7. 明确不照搬

| 参考库假设 | 为什么不能搬入本项目 |
| --- | --- |
| `MP4BoxReader`、`VapcReader`、`LegacyPackedVAPDetector` | 是 VAP/MP4 的解释器，不能提供任何 `.pag` 字节证据 |
| `AVAssetReaderFrameSource` 读 MP4 sample table，持续 copyNextSampleBuffer | 是 VAP 视频主播放管线；用户明确要求不搬入 PAG。外部 mp4/mov 仅是 PAG 图层替换资源，需另外设计局部帧提供器 |
| `VPKShaders.metal` 的 `rgbRect` / `alphaRect`、图像 locator 打孔 | 依赖 VAP packed video 与槽位遮罩布局。PAG 混合/遮罩只能根据 libpag 或 pag.io 证据实现 |
| `PlayerView: UIView`、`UIImage`、`UIFont`、`UIScreen` | UIKit-only；PAG 同时要求 AppKit 和 SwiftUI，不能把平台对象当成跨隔离核心数据 |
| `DynamicResolver.materialize` 在 MainActor 栅格化 | 其源码为 UIKit/TextKit 死锁规避而串行上主线程；本项目明确不允许解码和绘制阻塞主线程，需要选用另一条实现路径 |
| `SDWebImageRuntime` 的 selector / runtime 桥 | 本项目必须自己解码静图与动图，不探测或依赖 SDWebImage |
| `Package.swift` 的 Swift 5.9、iOS 15 | 本项目基线是 Swift 6.4、iOS 26/macOS 26，严格并发；参考库的 unchecked Sendable 声明不能作为安全证明 |
| `AudioCoordinator` 和公开音频选项 | 不属于本项目首版的公开音频播放器范围 |
| `PlaybackAssetMode.ordinaryVideo` | 不能让载入 `.pag` 的入口接受普通 MP4 当作 PAG 播放 |

## 8. 后续验证用例建议

这里只列应转化为本项目 Swift Testing 用例的场景，不声称已经通过：

1. 相同文件并发载入只解析一次；路径对应文件替换后重新解析；清空缓存后旧任务完成不能重新填回；取消一个等待者不影响其他等待者。
2. 新载入、seek、替换发生后，旧 CPU 结果与 GPU 完成只释放其资源，不覆盖当前状态、不多发终态。
3. 文本放得下不滚；溢出才滚；pause/resume 连续；PAG loop 不重置；过大尺寸在分配前失败或按明确策略降级。
4. 空占位与空槽位不停止其他图层；静图单帧；GIF/WebP 多帧时序正确；系统不支持动画格式时有明确错误。
5. drawable 暂不可用、零尺寸、移出窗口与恢复不产生无界任务/帧缓冲；GPU 完成前输入纹理一直有效。
6. 三种宿主播放同一输入、时间与替换快照，共享 renderer，不存在独立绘制实现。

参考库已有相关测试入口：`Tests/VAPPlayerKitTests/VAPPlayerKitTests.swift` 中的 `testGlobalMetadataCacheCoalescesConcurrentInspections`、`testGlobalMetadataCacheReparsesAfterFileSignatureChanges`、`testFittingTextStaysStaticEvenWhenMarqueeIsRequested`、`testOversizedMarqueeStripFallsBackToTruncation`、`testRegularUIImageStaysStaticEvenWhenAnimatedPlaybackIsRequested`。它们只是行为索引，不能替代本项目的 `swift test` 验收。
