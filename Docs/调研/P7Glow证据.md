# P7 Glow tag61 源码与真实字段（2026-10-21）

`include/pag/file.h::TagCode`确认61为`GlowEffect`。只读上游`src/codec/tags/effects/GlowEffect.cpp::GlowEffectTag`按阈值`SimpleProperty`缺省1、半径缺省100、强度缺省0，以及通用效果opacity与mask引用编码。`PAGGlowEvidenceTests`逐项完整消费`nodegroup_clip1.pag`三个真实tag61子流：合成31的预合成层115为阈值1、半径0、强度1；层132为阈值约0.243137、半径48、强度1；层149为阈值约0.8、半径42、强度1。三层opacity255、mask引用空；阈值和半径均有动画，层132的强度也有动画。层115的效果顺序为MotionTile→Glow→Bulge，另两层只有Glow；编码顺序见`/private/tmp/pag-glow-evidence-order.log`，字段见`/private/tmp/pag-glow-evidence.log`。

`src/rendering/filters/glow/GlowFilter.cpp::Apply`对输入作横向、纵向`GlowBlurRuntimeFilter`后，与原输入交给`GlowMergeRuntimeFilter`；`GlowMergeFilter.cpp`先以预乘RGB逐通道取`max(src, blur)`、再除以阈值并钳到0...1，alpha取原输入。当前上游`Apply`读取radius和threshold，但未在该函数或Merge中使用`glowIntensity`；这不能据字段名称把强度变化擅自解释为额外亮度，也不能把tag61无条件忽略。真实radius/threshold动画以及多层效果顺序需在同一帧分别采样。Glow发生于Effects链内，早于tag63动态MotionBlur及整层Screen混合。

本轮仅完成真实载荷与上游语义取证，正式解码仍明确`unsupportedFeature("layerTag:61")`。下一步须核对GlowBlur具体采样核、两轴局部附件范围、效果顺序和可见帧，再实现有界GPU组合及挂载drawable实像；上游逐像素金图仍未建立。
