# 经典 libpag 行为证据

本报告为 `Docs/架构设计.md` 提供只读源码证据，不是已实现 API，也不把原版实现细节自动提升为 Swift 架构要求。调研日期 2026-09-28；参考根目录 `/Users/arthas/shibo/iOSProject/libpag`，当前 HEAD 为 `380e5cddcdacd3d15be785cb2e2dccd2f0c8f002`。以下源路径相对该参考根目录；符号是定位依据，后续实现应重新核对涉及的完整函数与版本。

## 公开职责与 Swift 边界建议

| 原版事实与证据 | 对 Swift 设计的建议（待架构决定） |
| --- | --- |
| `src/platform/cocoa/PAGFile.h`：路径、内存载入；可编辑文本/图片数，视频合成数；`getTextData` 始终返回原始文本；`copyOriginal` 不保留运行时修改。 | 不可变的已解析文档与可变播放/替换会话分离；载入器返回经过完整验证的文档；原始文本与当前替换值分开查询。 |
| `src/rendering/layers/PAGFile.cpp`：`Load → File::Load → MakeFrom`；`MakeFrom` 先构造图层树，要求根为 PreCompose，再定位时间 0。 | 解析成功不是读到文件头，需引用解析、完整性校验后才公开可播放内容。内部格式类型不公开。 |
| `src/platform/cocoa/PAGComposition.h`、`PAGLayer.h`：合成有尺寸和孩子；图层有种类、名称、可见性、起始时间、时长、父层等。 | 公开只读 `Sendable` 图层快照/稳定身份，内部持有时间轴及资源；不要为只读观察需求照搬可变 ObjC 继承树。 |
| `src/platform/cocoa/PAGPlayer.h`：关联 composition/surface，定位进度，`prepare` 收集 CPU 工作并异步准备，`flush` 提交待应用修改。 | 播放会话管理时间、替换版本和提交一致性；求值与 Metal 编码在后台；宿主仅管理显示目标和窗口生命周期。 |
| `PAGPlayer.h::setComposition`：同一原版合成不能同时属于两个播放器，赋给新播放器会移出旧播放器。 | 共享不可变解析数据、独立会话状态，明确主动改进此旧引用所有权限制，避免两个宿主抢同一可变图层树。 |
| iOS `PAGView.h : UIView`，macOS `PAGView.h : NSView`；原版没有 SwiftUI 宿主。 | SwiftUI 是同一 UIKit/AppKit 显示宿主的库内封装，三者共享同一渲染与时间实现。 |
| `PAGSurface` 在原版可不依附视图；存在离屏能力。 | 本项目仅保留“渲染目标与视图分离”的职责。可接外部显示目标，不据此设计 MakeOffscreen、截图或 CPU 像素 API。 |

## 时间、播放与缩放

证据：`src/platform/cocoa/PAGLayer.h`、`src/rendering/layers/PAGLayer.cpp`、`src/base/utils/TimeUtil.h`、`src/rendering/PAGPlayer.cpp`、`src/platform/{ios,mac}/PAGView.h`、`src/rendering/PAGAnimator.cpp`。

- 公开绝对时间单位为微秒；格式内部大量时间是 `Frame`。`DataTypes.cpp::ReadTime` 读的是编码无符号帧值，不能因为函数叫 Time 就直接当成微秒。
- `TimeToFrame(time,fps) = floor(time × fps / 1_000_000)`；`FrameToTime(frame,fps) = ceil(frame × 1_000_000 / fps)`。图层 `startTime` 可以为负；可见区间为 `[startTime, startTime + duration)`。
- `PAGLayer::setProgressInternal` 使用 `startTimeInternal() + ProgressToTime(progress,durationInternal())`。`ProgressToTime(1,duration)` 返回 `duration - 1`，所以进度 1 指向最后可见时刻，不是右开区间外的结束时刻。
- `PAGLayer::currentTimeInternal` 把当前帧转回微秒；读回值是帧量化结果，未承诺原样返回 seek 输入。
- `getProgressInternal` 使用 `FrameToProgress(contentFrame,totalFrames)`：`totalFrames <= 1` 或负帧返回 0；末帧或之后返回 1；中间帧为 `(frame + 0.1) / totalFrames`。这是上游规避帧边界的实现，并不是 `setProgress` 的数学逆函数。Swift 合同必须说明自己的读回约定，不许同时承诺帧兼容与精确互逆。
- 上游 `ClampProgress` 实际执行取余，非简单夹到闭区间；`progress == 1` 保持末端，超界值可环绕。核心合同只要求 `0...1`，Swift 可拒绝越界和 NaN/Infinity，但应把此差异明写为输入校验，不伪称沿袭旧实现。
- `PAGPlayer::setProgress` 在最大刷新率低于合成帧率时先以较低帧数重采样进度。不能把屏幕刷新率、内容帧率、时间单位混成同一参数。
- `PAGView.play` 从当前位置开始；已播放时再次调用无作用。`pause` 保持当前位置；iOS/macOS `stop` 明确目前等价于 `pause`，实现均调用 animator cancel。若 Swift 要回起点，应另设显式 rewind 行为，或明确写为有意语义变化。
- `repeatCount` 是总播放次数，默认 1；小于等于 0 为无限。不能误实现为“首次之外再重复 N 次”。`PAGAnimator::start` 在已自然结束后会回到进度 0 再播。
- `PAGScaleMode.h`：None 不缩放，Stretch 拉伸，LetterBox 等比留边且为默认，Zoom 等比铺满裁切。`PAGPlayer.h` 说明设置自定义 matrix 会将 scaleMode 设为 None。首版若只需要四种缩放，无须提前公开任意矩阵写接口。

## 替换身份、原值与文本

证据：`src/platform/cocoa/PAGFile.h`、`PAGImageLayer.h`、`PAGText.h`；`src/rendering/layers/PAGFile.cpp::{getLayersByEditableIndexInternal,replaceTextInternal,replaceImageInternal}`；`PAGImageLayer.cpp::setImageInternal`。

- 文本与图片各自拥有 editableIndex 空间。一个 index 能命中多个同类图层；文件级替换会替换同一文件、同一 index 的全部对应层。
- `PAGFile::replaceImageByName` 查找所有同名图层，再仅替换 Image 层；不能默认名称唯一，也不能只替换第一个。
- 传入 null 恢复文件原始文本/图片，不是清空为透明。Swift 应区分“恢复原始值”和“无占位透明槽位”。
- 图层级 `PAGImageLayer::setImage` 只影响该层；旧 `replaceImage` 已废弃，旧行为曾影响同 editableIndex 的全部关联层。首版文件级替换可省掉历史二义性 API。
- `getEditableIndices` 可能筛出允许编辑的子集；不能仅凭 `0..<numImages` 或 `editableIndex >= 0` 就认定当前文件允许编辑该层。
- `PAGFile::BuildPAGLayer` 明确将格式中的 vector layers 逆序构造公开孩子数组。绘制顺序、公开层序和 matte 邻接关系必须分别确认，不能顺手用一个数组顺序解释所有语义。
- `PAGImageLayer::setImageInternal` 更新引用、通知内容修改并使缓存缩放失效。Swift 替换成功必须增加内容版本，使旧求值/解码结果不能覆盖新素材。

`PAGText.h` 支持文本字符串、字体族/样式/像素字号、伪粗体/斜体、填充/描边开关和颜色、描边宽、段落对齐、行距、字距、背景色及背景 alpha。`leading == 0` 表示从字体度量自动计算；backgroundAlpha 范围为 0...255。`baselineShift`、`boxText`、`boxTextRect`、`firstBaseLine`、`strokeOverFill` 注释注明外部修改无效。Swift 值型文本替换应保留原始只读布局字段，不把所有头文件属性机械做成任意可写属性。跑马灯是本项目运行时表现，不是新增 PAG 字节字段。

## 内嵌视频与外部替换视频

### PAG 文件内部视频序列

- `src/codec/tags/VideoCompositionTag.cpp::ReadVideoComposition` 与 `ReadTagsOfVideoComposition` 将 VideoSequence 挂到视频合成；这是文件内部序列，不是相邻路径上的 MP4。
- `src/codec/tags/VideoSequence.cpp::ReadVideoSequence` 明确读取序列尺寸、帧率、可选 alphaStartX/Y、SPS/PPS、关键帧位、各帧时间和 NALU 数据，以及可选静态时间区间。此处是证据索引，不可省去 `DecodeStream`、`ReadTime`、`NALUReader` 的读取规则后拼造字节。
- `src/codec/utils/NALUReader.cpp::ReadByteDataWithStartCode` 是载荷转 NALU 表达的证据；`src/rendering/sequences/VideoSequenceDemuxer.cpp` 把 headers/samples 交给解码，声明 MIME `video/avc`，时间经帧/微秒变换，有关键帧 seek 与重排序约束。
- `VideoSequenceDemuxer` 使用 BT601_LIMITED，maxReorderSize 2。Swift 必须核对解码输出颜色元数据和实际 Shader 变换，而不是把所有视频一律当作任意默认 RGB。
- 禁止 VAP 分屏 alpha 不等于删掉 PAG 自己有证据的 alpha 布局。PAG 的 alphaStartX/Y 必须按照 PAG 序列字段解释；外部普通 MP4/MOV 不能被强行解释成左右分屏 alpha。
- 可选 `Mp4Header` 是内部序列相关标签，不是“读取外部 MP4 代替 PAG”的依据。

### Viewer 接受的替换素材

- `viewer/assets/qml/ImageListView.qml` 的过滤器列出 jpg/jpeg/bmp/png/mp4/mov。
- `viewer/src/editing/PAGImageLayerModel.cpp::changeImage` 先尝试 `PAGImage::FromPath`，失败后尝试 `PAGMovie::MakeFromFile`，最终走 `PAGFile::replaceImage`。它替换的是图像槽位，不提供公开“替换视频轨”方法。
- `viewer/src/video/PAGMovie.h`：PAGMovie 继承 PAGImage；`getGraphic` 通过 SequenceImageProxy 获取对应帧；`isStill` 为 false。Swift 可用统一图像素材枚举/描述区分静图、动画图片、外部电影，不需要给 PAG 文件装载入口塞 MP4。
- `PAGMovie.cpp::getContentFrame` 将素材时间限制在选定范围并钳到末帧；speed <= 0 时保持开始帧。首版不必公开裁切/变速，但需明确素材不足时保持末帧，不能默默自行循环。
- `PAGImageLayer.cpp::getCurrentContentTime` 对根文件中的替换素材使用内容时间重映射；没有根文件才是 `layerTime - startTime`。后续涉及 timeRemap/伸缩的文件必须依据该路径实现，不能把所有层都假定线性本地时间。
- Viewer 使用 Qt/ffmovie，不能据此推定 Cocoa SDK 已有外部视频播放 API，也不要求 Swift 复制其平台依赖或音频播放。Swift 使用系统框架实现独立素材解码，具体 Apple API 并发/时钟行为另行验证。

## 平台宿主与性能边界

- iOS `src/platform/ios/PAGView.mm::layerClass` 返回 CAEAGLLayer；`private/PAGSurfaceImpl.mm::FromLayer` 创建 GPUDrawable。macOS `src/platform/mac/private/GPUDrawable.mm::FromView` 使用 CGLWindow。这两条旧渲染后端不移植。
- 原版 macOS `PAGView.mm::initPAG` 设置 animator 同步以满足 CGL surface 创建；这不是 Swift Metal 渲染必须阻塞主线程的证据。
- 两平台宿主都负责尺寸变化、窗口/可见生命周期；动画 listener 转主线程。Swift 只把这些 UI 职责放 MainActor；解析、求值、视频解码、Metal 编码留在专属后台隔离域。
- 原版缓存选项包括静态层位图缓存、缓存缩放、磁盘缓存（`PAGPlayer.h`）。本项目可优先缓存不可变解析结果、字体排版、路径几何、纹理和视频最近帧；不据此建立“整帧离屏 → 屏幕拷贝”的默认路径。
- 最终颜色附件直接绑定当前 CAMetalDrawable.texture；遮罩/滤镜如需中间资源，须有对应效果理由和预算。不能把每帧全画面中间纹理当作无条件入口。播放不调用像素读回，不提供离屏出图 API。
- iOS 伞头有 `PAGDecoder`、`PAGImageView`，macOS 伞头没有；这些不是三平台共用播放器的起点。两边均有音频 bytes/markers 暴露，Cocoa 公开接口没有音频播放器。

## 解码证据索引与成功门槛

| 层级 | 需要一起核对的上游文件与符号 |
| --- | --- |
| 入口 | `src/rendering/layers/PAGFile.cpp::Load/MakeFrom` → `src/base/File.cpp::Load` → `src/codec/Codec.cpp::Decode` |
| 文件头与版本 | `Codec.cpp::ReadBodyBytes`；`src/codec/CompressionAlgorithm.h`、`Version.h`。读取固定头共 9 字节，含 End 标签的最短输入检查为 11 字节；version 3 为 EncryptedVersion，明确失败。UNCOMPRESSED 为字符 `U`（0x55），不是零。 |
| 边界、整数、位流 | `src/codec/utils/DecodeStream.{h,cpp}`；`src/codec/DataTypes.cpp::ReadTime/ReadRatio/ReadColor`。`readEncodedInt32/64` 的最低位是符号、其余位是绝对值，不是常见 ZigZag。DecodeStream 的 DataView 引用为 `tgfx/core/DataView.h`，本地在 `third_party/tgfx/include`；只用作上游调用的追踪证据，不引入 tgfx 依赖。任何 signed、varint 或 bit 对齐都必须看实现。 |
| 标签框架 | `src/codec/TagHeader.cpp::ReadTagHeader`、`TagHeader.h::ReadTags`；标签代码枚举在 `include/pag/file.h::TagCode`，不得凭记忆填魔数。 |
| 文件标签分发 | `src/codec/tags/FileTags.cpp::ReadTagsOfFile`；对应 FontTables、Images、EditableIndices、TimeStretchMode 文件。 |
| 合成 | `VectorCompositionTag.cpp`、`BitmapCompositionTag.cpp`、`VideoCompositionTag.cpp`、`CompositionAttributes.cpp::ReadCompositionAttributes`。 |
| 图层与属性 | `LayerTag.cpp`、`LayerAttributes.cpp`、`LayerAttributesExtra.cpp`；`AttributeHelper.h`、`Attributes.h` 定义属性存在标记、静态/关键帧和插值读取。 |
| 内容 | `Transform2D.cpp`、`SolidColor.cpp`、`text/TextSource.cpp`、`ShapeTag.cpp`、`shapes/*`、`ImageReference.cpp`、`ImageBytes*.cpp`、`BitmapSequence.cpp`、`VideoSequence.cpp`。 |
| 引用与验证 | `Codec.cpp::InstallReferences`、`VerifyLayerParentChains`、`MeasureCompositionDepth`、`VerifyCompositionGraph`、`VerifyAndMake`，以及各模型 `verify()`。 |

上游 `Decode` 的顺序是 ReadBodyBytes → ReadTags → InstallReferences → VerifyAndMake → UpdateFileAttributes。VerifyAndMake 要求非空合成并验证合成图、父链和内容对象；当前图嵌套上限为 128。Swift 必须先建立完整、闭合、受预算限制的解析结果，再暴露成功。

有意更严格的建议：上游 ReadBodyBytes 会将声明 bodyLength 夹到剩余字节，未知文件级标签也可能忽略。核心要求“残缺结果不算成功”；Swift 可报告 truncated/unsupported，不能仿照宽容分支而把丢失的必要内容当作成功。未知标签要按是否影响所需画面区分，无法确认安全忽略时明确失败，不能“略过以后看起来能播”。这属于明确记录的产品安全边界，不是格式新事实。

进程缓存注意：上游 `File.cpp::FindFileByPath` 仅按路径找 weak 引用，并没有同路径文件修改失效或并发 single-flight 保证。Swift 必须按核心合同补文件身份/版本、并发去重和迟到提交门槛，不能照抄路径缓存。

## 建议阶段验收边界

1. **基础合同与读取器**：微秒/进度/帧边界及重复规则有纯单元测试；边界读取器对截断/越界/溢出失败。此阶段不对外宣称成功加载 PAG。
2. **完整文档解码的首个支持闭包**：用真实资源选定完整的功能集合，沿完整流程解析根、子合成、图层、引用与必要内容。成功样例输出尺寸/时长/编辑身份；所有不在支持闭包中的必要图像特征报 unsupported。只有头部/元数据结果只能叫 inspection，不能冒充可播放 document。
3. **时间求值与替换**：按真实文件检验层序、负起点、右开可见区间、末进度、同索引多层/同名多层、恢复原值；时间重映射未实现时拒绝相关文件，不按线性猜。
4. **Metal 直接呈现与三宿主**：同一资源/同一时刻在 SwiftUI、UIKit、AppKit 使用同一帧计划，GPU 调试确认当前 drawable 是最终目标，无无条件整帧离屏拷贝、无播放读回。库测试仍为 swift test，平台集成再 xcodebuild。
5. **内嵌视频、外部电影与动态图**：分别验收，解码时钟都受会话时间和 generation 控制；暂停、seek、替换后迟到结果不回写。内嵌 PAG alpha、外部普通电影和 GIF/WebP 三类来源不能共用未经验证的格式假设。

本报告未运行上游、未改参考源码、未实现生产代码。Apple 系统动态图解码能力、最终 Metal Shader、各资源具体特性覆盖需要在对应实现阶段实测，不能由本报告推定通过。
