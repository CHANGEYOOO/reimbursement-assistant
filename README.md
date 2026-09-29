# 报销单助手

这款本地工具把支付或订单截图整理成可用 WPS 打开和打印的 Excel 报销单。Mac 版还可保存报销单草稿、管理发票并单独导出发票文件夹。截图和发票只在本机处理，原文件不会被修改。

## 打开

从 [Releases](https://github.com/CHANGEYOOO/reimbursement-assistant/releases) 下载 Mac DMG，双击后把“报销单助手”拖到“应用程序”文件夹。如果首次打开时 macOS 提示来源未知，在 Finder 中按住 Control 点按应用，选择“打开”，再按系统提示确认。

需要重新生成独立应用时运行 `./scripts/build-app.sh`；需要重新生成安装镜像时运行 `./scripts/build-dmg.sh`。构建需要安装 Swift 命令行工具。

## 使用

1. 新建或打开报销单，填写标题，点“导入截图”选择多张 PNG、JPEG 或 HEIC；也可以从 Finder 文件夹把这些图片直接拖入软件窗口，支持分批追加。草稿自动保存在本机，导入的截图会复制到草稿中。
2. 等待本机识别完成，逐条核对日期、用途和金额。日期优先取截图中的支付或交易日期；手动输入 `20260924` 时会自动显示为 `2026-09-24`。金额无法确定时可点击候选金额；手动选分类会自动标记“已人工核对”，也可以用“全部标记已人工核对”处理当前报销单。重复截图会提示并排除在合计与导出之外。
3. 单击记录可蓝色高亮选中，按住该行拖动可调整顺序。点击缩略图查看原图大图，再点击大图收起。确认底部条数和合计。
4. 点“导出 Excel”，在系统保存窗口选择位置。若按钮不可用，窗口底部会说明需补全的项目。保存后用 WPS 打开 `.xlsx`，检查图片、金额和打印预览。

导出表的五列依次为“序号、日期、名称、图片、金额”，末尾有合计。关闭应用后可从保存的草稿继续编辑。

## Mac 发票夹

切换到“发票夹”，可批量导入 JPG、PNG、HEIC、PDF 或包含这些发票的 ZIP。ZIP 中的汇总表不会计入发票。发票金额优先从文件名读取；文件名没有明确金额时读取 PDF 内容或进行本机文字识别，识别不准可手动修改。界面显示发票合计与订单金额的差额。

导出发票时选择一个父文件夹。软件按发票购买方抬头分组，各组另建文件夹，名称为“导出日期-该组发票总金额-购买方抬头”；每张发票保持原格式。购买方识别不到时可在发票夹填写备用抬头。发票不会放进订单 Excel。

## Windows 版

从 [Releases](https://github.com/CHANGEYOOO/reimbursement-assistant/releases) 下载 Windows EXE，复制到 64 位 Windows 电脑，双击运行即可。Windows 版沿用同一图标和五列顺序，支持批量导入或拖入 PNG、JPEG、HEIC，核对后导出 `.xlsx`。金额无法确定时可点击候选金额，点选后自动标记人工核对。识别所需的中英文数据已封装在 exe 中，截图在本机处理。Windows 上的实际操作和 WPS 打开效果由用户手动验收。如识别时提示缺少原生 DLL，请先安装 [微软 Visual C++ x64 运行库](https://aka.ms/vs/17/release/vc_redist.x64.exe)。

重新生成 Windows 版需要 .NET 10 SDK。在项目目录执行：

```sh
dotnet publish Windows/ReimburseApp/ReimburseApp.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=None -o build/Windows版-1.2
```
