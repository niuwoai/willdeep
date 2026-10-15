# 插件参考图路径门禁修复

版本：1.421.0-rc2 / build922。只修本仓库过时测试门禁与版本元数据，产品 Swift 与固定插件实现不变。

interaction 完整10步骤、107项检查通过。真实固定插件 frame_plan、ReferenceLegend 与后端分发保留有序 filePath；只注入一次本地后端桩，不选择 Provider。6项回归包含 Legend 前后替换 mediaURL 和后端丢路径反例，参考包编译桩在 ensure 中恢复。真实模型/Provider 请求为0。

首次原门禁24/25失败记录保留，原因是对已重构插件源码做旧字面串匹配。实际插件文件与gitlink64abc20一致。

远端CI run38728615967的interaction在Checkout前缺少PLUGIN_SUBMODULES_TOKEN，测试未执行；仓库没有在线self-hosted macOS runner。未改工作流、未复制个人令牌、未声明远端CI全绿。正式本地门禁另有既有同批原生免费测试与本次独立签名公证产物核验。rc1历史包保留，rc2按新源码重新构建。

质量门禁完整10步骤通过，版本1.421.0-rc2/build922一致，diff检查通过。
