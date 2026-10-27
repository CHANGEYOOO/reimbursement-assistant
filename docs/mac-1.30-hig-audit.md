# macOS 原生界面审查与分阶段改进

审查日期：2026-10-28。范围为当前 SwiftUI 界面代码与离线检查，非 Apple 认证或完整辅助功能验收。

## 现状

已有系统字体、SF Symbols、语义前景色、Settings 和原生文件选择器；主要业务使用独立 Store，不需要重写。

需要改进：
- ReviewView 根导航使用 HSplitView 和自定义按钮侧栏，选择状态与键盘导航由应用模拟。
- 发票预览默认宽度仅320点，最大500点；PDF整页适配且计算发生在布局前，不能稳定随窗口改变。
- 发票箱 LazyVGrid 卡片和固定宽筛选器挤占内容空间；窄窗口适配不足。
- 项目操作、筛选、导出散落多个 HStack，尚未统一窗口 Toolbar。
- 订单为自定义可编辑行，需要在保留拖动排序、输入焦点和批量核对行为的前提下评估 Table，不能直接替换。
- 状态提示、空状态和图标按钮的辅助功能描述需统一；深浅模式、系统强调色和键盘操作需真实窗口验收。

## 分阶段

1. 本轮：共享附件预览按可用宽度显示，支持面板调整、窗口缩放与长页滚动；扩大可调预览宽度。根导航采用 NavigationSplitView 和原生 List 侧栏。
2. 后续：发票箱改原生列表、保留按收件月份分组及月度全选，筛选改自适应布局；再评估订单 Table，不改变列顺序或拖动排序。
3. 后续：统一 Toolbar、搜索、详情入口、空状态和状态提示；进行深浅模式、强调色、缩放、VoiceOver 与键盘验收。

所有阶段保留识别、邮箱、缓存、导出与数据格式。Windows开发保持暂停；不自动发布GitHub。

参考：
- https://developer.apple.com/design/human-interface-guidelines/split-views
- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/toolbars

## 本轮检查

共享预览离线检查通过：首次PDF布局、改变面板宽度、缩放复位、90/270度旋转页、极端缩放范围和长图保持比例。安装包采用Mac1.30（构建34）。完整应用编译、签名及磁盘映像校验均已通过。未连接真实邮箱或调用付费API；实际深浅模式、键盘导航与窗口视觉效果仍需人工验收。
