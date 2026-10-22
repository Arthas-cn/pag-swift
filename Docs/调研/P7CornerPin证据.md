# P7 CornerPin tag58 字段与组合取证（2026-10-21）

只读上游`src/codec/tags/effects/CornerPinEffect.cpp::CornerPinEffectTag`依次定义四个Spatial Point（upperLeft、upperRight、lowerLeft、lowerRight），随后由`EffectCompositingOptionTag`读取effectOpacity与自定义mask引用。`src/base/effects/CornerPinEffect.cpp::transformBounds`把四角的轴对齐包围盒作为输出范围，`visibleAt`始终为true。`src/rendering/filters/CornerPinFilter.cpp::Apply/computeVertices/calculateVertexQs`按当前层帧取四角，并把输入纹理四角作为UV，以对角线交点的q完成四边形透视采样；非正常交点时退化到q=1。`src/rendering/renderers/FilterRenderer.cpp::ApplyEffects`按文件效果顺序逐个作用，不能把同层两个效果任意交换。

`PAGCornerPinEvidenceTests`完整消费两份真实tag58载荷，日志`/private/tmp/pag-corner-pin-field-audit.log`：`motiontile_text_corner.pag` Image层187，效果顺序[56,58]，四角静态，其中右下角(310,308)；`cornerpin-bulge.pag` Image层114，顺序[58,59]，四角均动画。两者effectOpacity均255、无自定义mask。先前MotionTile/Bulge单效果根drawable直采已验收，但该证据不能直接证明串联的采样顺序。

实现只接受无图层mask/样式/替换裁边的Image，独立tag58及上述两个顺序。四角变换到原图像素基准，求逆单应矩阵；根pass在四角包围矩形内按输出点反求上游效果输入UV，越出四边形透明。[56,58]先把CornerPin逆映到MotionTile输出单位域，再调用既有平铺采样；[58,59]先从Bulge输出逆映到CornerPin的包围域，再由CornerPin逆映到原图。多效果或退化/反折四边形保持明确unsupported，不用错误画面放行。

正式验证：`MetalCornerPinFileTests`对两份真实文件各60源帧执行生产Metal准备、根pass与附件归还；同一macOS挂载drawable的首中末帧与去效果原图对照，`motiontile_text_corner.pag`在64×64采样网格有414个非透明点/399个差异点，`cornerpin-bulge.pag`有3312个非透明点/2125个差异点。两色合成输入在非仿射四角内得到左红右绿、四边形外透明精确像素金值；它验证投影片元，不冒充PAG字节。完整库**1424项/275组通过**（`/private/tmp/pag-corner-pin-full.log`），126资源**114通过/12明确unsupported**（`/private/tmp/pag-corner-pin-audit.log`），解析revision28。现有画面证据并非上游逐像素金图；反折/退化四边形、其它排列与自定义效果mask仍明确拒绝，正式Demo整帧及P9跨平台复核未做。
