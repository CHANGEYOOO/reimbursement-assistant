# 本地电子发票筛选：架构分析、方案与验证

本报告记录Mac1.31的独立本地引擎。Mac1.32增加了默认关闭的[可选AI兜底](mac-1.32-invoice-ai-fallback.md)，本地引擎本身仍不联网。

## 目标与边界

从混合附件筛选目标电子发票，不建设通用OCR引擎。所有分类在本机执行；不调用AI、云OCR或网络验真。文件类型检查不等于税务真伪或数字签名认证。

接受范围：数电普通/增值税专用发票、传统增值税电子普通/专用发票。铁路电子客票、航空运输电子客票行程单不在白名单。

## 原有链路与问题

本地项目 InvoiceStore、发票箱 InvoiceInboxStore、邮箱 QQMailboxParser 均有附件入口。旧分类器先OCR再检查关键词，只要求存在号码形状与字段标签，缺少绑定字段值及金额勾稽。旧项目导入丢弃非invoice结果，旧数据重检把unknown变nonInvoice；发票箱界面也把unknown合并到排除。格式白名单散落多个入口，仅支持PDF和图片。

## 方案

独立LocalInvoiceContent负责受限的PDF/OFD/XML内容读取；InvoiceDocumentClassifier只负责白名单及组合校验，返回invoice/nonInvoice/unknown与具体理由。分类输入自行读取原文件，不信文件名、扩展名或调用方OCR文本。PDF逐页验证，混合页面不自动保留。结构化XML须为已知结构及正确父子关系，OFD沿文档引用读取页面、模板与语义数据，不收集任意XML标签拼成发票。

字段：票种标题、绑定发票号码、传统发票代码、有效开票日期、双方名称与税号、不含税合计、税额、价税合计。金额勾稽允许小额舍入差，符号须一致。无法提取、加密、扫描、未知结构或缺字段均待确认。人工修改金额不能改变文档分类。

三类结果均保留记录与判断依据；非发票及待确认不自动进入项目有效发票总额、分配或导出。待确认可通过独立“人工确认是发票”操作放行，并保留unknown原判定和人工来源标记；明确nonInvoice不能强制放行。排除指排除有效集合，不删除邮箱原件或用户源文件。邮箱文件名只用于候选发现；不得仅凭名称拒绝附件。

## 实际源码研究

源码只用于理解设计，没有复制外部项目代码或引入其运行时。

- pdf_invoice_parser，e3056e3b9a231a252331a4f32906a56bc1834982：PDFBox文本与坐标，contains电子发票切换解析器；OFD经ofdrw转PDF。没有严格附件白名单与强制字段/金额门槛，未找到LICENSE，不复制代码。
  - https://github.com/jiangnanboy/pdf_invoice_parser/blob/e3056e3b9a231a252331a4f32906a56bc1834982/src/main/java/sy/service/PdfInvoiceExtractor.java
  - https://github.com/jiangnanboy/pdf_invoice_parser/blob/e3056e3b9a231a252331a4f32906a56bc1834982/src/main/java/sy/controller/Controller.java
- dsh-invoice-tools，b1c8ee8f6ce6573e1de06587d428d331a0cfd02a，MIT：优先PDF嵌入XML，其次文本，输出字段来源和金额勾稽结果。校验失败仍parsed、缺失字段可能置零；自写PDF解析仅覆盖部分对象/编码，不能直接作为筛选器。借鉴结构数据优先和金额交叉校验思想，原生解析替代自写PDF解码。
  - https://github.com/988hj7tczd-oss/dsh-invoice-tools/blob/b1c8ee8f6ce6573e1de06587d428d331a0cfd02a/src/pdf-extract.ts
  - https://github.com/988hj7tczd-oss/dsh-invoice-tools/blob/b1c8ee8f6ce6573e1de06587d428d331a0cfd02a/src/invoice-model.ts
  - https://github.com/988hj7tczd-oss/dsh-invoice-tools/blob/b1c8ee8f6ce6573e1de06587d428d331a0cfd02a/src/tools/invoice-parse.ts
- einvoice，778028eaca9d239ac9a2b25dfdedb39157d104a5，MIT：PDFBox；OFD读取固定original_invoice.xml及第一页，默认普票、标题含专用改专票。没有严格非票排除或强制勾稽门槛。实际另一个项目OFD样本采用CustomTag/ObjectRef指向TextObject，不能仅支持固定XML路径。
  - https://github.com/sanluan/einvoice/blob/778028eaca9d239ac9a2b25dfdedb39157d104a5/src/main/java/com/sanluan/einvoice/service/OfdInvoiceExtractor.java

未运行外部项目；上述结论来自源码及OFD压缩包结构检查。

## 当前覆盖范围与限制

- PDF：PDFKit原生文本及坐标重排；CoreGraphics读取Names/EmbeddedFiles命名树（含Kids）的受支持XML。内嵌数据与可读票面号码、代码、日期、双方名称税号及金额税额必须一致，不能凭嵌XML把扫描件自动放行。多页有嵌数据映射歧义时待确认。
- OFD：单文档单页、OFD.xml引用链、页面及模板文字、CustomTag/ObjectRef字段映射，交叉核对元数据。多页、无该映射或其他供应商结构待确认；未引入OFD可视渲染器。
- XML：已支持Invoice/EInvoice/root直接发票字段结构，要求明确票种标题和完整字段；未知命名、仅有数字票种码、缺标题或其他XML schema均待确认，不承诺覆盖所有开票系统。
- 双方税号缺失（包括部分个人普票）将待确认；保留独立人工确认入口。用户此前提供的7C55D9E1-9C37-495A-8D52-099A2FC62151.pdf在本次检查中仍为待确认，理由为无法可靠绑定购买方税号；未通过降低门槛强行放行。购买方/销售方不是仅靠标签存在即通过。
- 限额：文件25MB、PDF100页；XML2MB、深度64、节点50000；OFD最多500条目、读取XML总量16MB。超限待确认。
- XML禁止DTD/外部实体，OFD只流式读取内部XML、不落盘展开；ZIP复用项目已有路径、符号链接、条目数及大小检查。无法解析的源文件不删除。
- 类型筛选不验证税务真实性、税号注册真实性或数字签名。手动确认会明确标记来源，不伪装为自动识别。

## 验证记录

测试仅使用隔离目录，不连接真实邮箱、不调用付费API、不修改用户项目。已通过以下离线检查：

| 检查 | 结果 |
| --- | --- |
| 27个文本用例 | 通过：数电普通/专用、传统电子普通/专用、滴滴行程单、酒店明细、订单伪字段、金额/日期/重复字段/票种冲突、免税及红字票面 |
| 实际生成PDF | 通过：数电及传统发票、混合发票+明细页、扫描件、加密件 |
| PDF内嵌XML | 通过：命名树Kids、匹配票面、销售方冲突、金额税额改变但总额相同的冲突 |
| XML/OFD | 通过：支持结构、未知结构、重复字段、DTD/UTF-16实体、损坏OFD；两个开源真实OFD样本通过完整字段校验 |
| InvoiceConfirmationCheck | 通过：三态持久化、仅有效集合导出、人工确认来源、明确非票不可确认、策略升级清旧人工确认 |
| InvoiceInboxCheck | 通过：去重、项目分配、三态结果保留、修改金额不放行、人工来源随副本保留、自动处理计数、安全ZIP路径拒绝 |
| InvoiceTitleRetryCheck / QQMailboxCheck | 通过：抬头补充、邮箱编码、混合候选内容检查，不连接邮箱 |

Mac1.31（构建35）完整编译、应用签名检查及DMG完整性校验均通过。实际用户操作、真实邮箱收取与视觉验收仍未执行。

复现核心分类检查：

```sh
swiftc -swift-version 6 -D DIRECT_TEST_RUNNER Sources/ReimburseApp/InvoiceDocumentClassifier.swift Sources/ReimburseApp/LocalInvoiceContent.swift Tests/ReimburseAppTests/InvoiceDocumentCheck.swift -o /private/tmp/invoice-document-check
/private/tmp/invoice-document-check
```

样本与临时测试数据保留在隔离临时目录，不删除用户文件。

