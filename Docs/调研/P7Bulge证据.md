# P7 Bulge tag59 字段与图像子范围（2026-10-21）

只读上游 `src/codec/tags/effects/BulgeEffect.cpp::BulgeEffectTag` 与 `EffectCompositingOption.cpp` 证明八项统一 flags：Simple horizontalRadius、Simple verticalRadius、Spatial bulgeCenter、Simple bulgeHeight、Simple taperRadius、Discrete pinning、Simple effectOpacity、自定义 mask 列表。`src/base/effects/BulgeEffect.cpp::visibleAt` 仅在高度和双半径均非零时启用。`src/rendering/filters/BulgeFilter.cpp::Apply/filterBounds` 把中心与半径按输入内容 bounds 归一；pinning 或高度零时输出 bounds 不变，否则仅椭圆触及内容时按中心±半径保守扩边。片元使用距离、角度和高度反求输入坐标；pinning 将取样钳在0.005...0.995，未固定时越界透明。现行滤镜没有使用 taperRadius，但字段必须完整消费，不能删除或猜测其编码。

`PAGBulgeEvidenceTests` 在七份原始文件中逐项消费九条 tag59 子流，日志`/private/tmp/pag-bulge-field-audit.log`。全部静态、effectOpacity=255、无自定义mask。`Bulge-unpin-s.pag`与`cornerpin-bulge.pag`的目标是Image层；前者半径628×345.5、中心约(1046,520)、高度约−0.485、taper311、未固定，后者先受tag58 CornerPin挡住。`bulgetext.pag`和`text1...4.pag`均为Text层，不能把文字当现成单幅纹理直采；它们需要先按内容bounds组合字形，再施加效果，属于后续局部效果附件范围。

后续Text分支的坐标证据：`include/pag/file.h::Effect::processVisibleAreaOnly`缺省false，Bulge未覆写；`src/base/TextLayer.cpp::getBounds`返回所属合成的完整逻辑尺寸。`src/rendering/renderers/FilterRenderer.cpp::MakeFilterList/GetContentBounds/GetLayerMatrix/DrawWithFilter`因而让Text按层矩阵画入以所属合成尺寸为坐标域的透明输入，再依编码效果顺序施加Bulge。实际着色只在glyph/背景区域有内容，可以借紧致局部GPU附件，但Bulge中心、半径、输出范围必须继续以**父合成完整尺寸**归一，并把滤镜反采样坐标转换为紧致附件UV；局部附件以外应透明。设计先写入[架构合同](../架构设计.md)，尚未把Text文件计通过。

首次正式Text目标测试五份文件均在解码的`bulgeLayerStyle`门禁停止，说明它们都有DropShadow样式，不能把无样式Text子范围算作实际资源进展。上游`FilterRenderer::ApplyFilters/DrawWithFilter`先应用Effect再应用LayerStyles，故保留现有投影外层、让其有界内容批次消费Text Bulge结果；在该组合验收前仍保持五份明确unsupported。

图像子范围已用现有输入纹理及根drawable直采：以ImagePlacement逆映中心和两轴半径，按上游bounds扩输出矩形，专用Metal片元将扩后坐标映回输入单位空间再取样。只对单个Image、默认效果opacity、无自定义/图层mask、无其它效果/样式及可表示的正半径开放；非Image明确`bulgeNonImage`，不把标签默默忽略。`Bulge-unpin-s.pag`经公开Loader首中末Metal准备和macOS挂载drawable开关效果的实际像素差分通过；完整库**1415项/270组通过**（`/private/tmp/pag-bulge-full.log`），126资源**111通过/15明确unsupported**（`/private/tmp/pag-bulge-audit.log`），解析revision27。尚缺上游逐像素金图、正式Demo整帧对照和文字层局部内容合成；真实固定pinning及高度动画尚未覆盖。

2026-10-21 Text层后续边界：按上述源码合同保留完整父合成输入域，在Metal中先把背景及所有字形轮次合成到实际非透明内容AABB加一像素透明halo的紧致GPU附件，再由根drawable片元以父合成坐标反采样Bulge；外层DropShadow另在效果之后消费结果。首次接线曾让投影内容附件达到512×288/290，原因是把Bulge的完整输出矩形误当非透明内容范围。按`BulgeFilter`仅改变椭圆内部采样这一证据，测量改为原文字/背景实际AABB与Bulge椭圆显示AABB的保守并集；真实文字输入附件约79×41/42，投影内容附件约77–78×41/42，`text4.pag`约256×156，没有无条件整帧中转。

五份真实文件均通过公开Loader、首中末帧计划和Metal准备，局部附件退出后活动字节为零。macOS测试进程的挂载drawable保留投影、只去Bulge作对照：`bulgetext.pag`及`text1...3.pag`按64×64网格有165/63/54/75点差异；`text4.pag`效果很弱，首帧按256×256密度、分批读测试像素有2点差异，其余两个时刻只验证了Metal准备，不能冒称三帧像素差分。完整库**1426项/276组通过**（`/private/tmp/pag-text-bulge-full.log`），126资源**119通过/7明确unsupported**（`/private/tmp/pag-text-bulge-audit.log`），解析revision29。正式Demo整帧、上游逐像素金图、其它Text效果排列和P9跨设备画面仍待后续。
