# Windows 安装包构建

1. 将应用发布为独立 Windows x64 程序（示例输出到 `build/windows-payload`）：

```sh
dotnet publish Windows/ReimburseApp/ReimburseApp.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o build/windows-payload
```

2. 从微软官方下载并保留 `vc_redist.x64.exe`（`https://aka.ms/vs/17/release/vc_redist.x64.exe`）。构建者应核对其官方来源；安装时读取随包运行库的主次版本号，只有本机已安装相同或更新版本才跳过；需要补装或升级时经用户同意执行，UAC 由 Windows 处理。

3. 生成嵌入清单和安装载荷。目标 ZIP 必须不存在；清理旧构建输出时遵守项目的废纸篓要求。

```sh
python3 scripts/package-windows-installer.py --payload-dir build/windows-payload --runtime build/vc_redist.x64.exe --output build/windows-payload.zip
```

4. 发布安装程序。它会嵌入上一步的 ZIP：

```sh
dotnet publish Windows/Installer/Installer.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o build/windows-installer
```

默认按当前用户安装到 `%LocalAppData%\Programs\报销单助手`，建立开始菜单和可选桌面快捷方式、Windows“已安装应用”卸载入口。报销项目和设置位于独立的 `%LocalAppData%\报销单助手`，卸载不会清理。

每个载荷文件按嵌入清单校验 SHA-256，并拒绝路径越界、重复路径、链接和异常大小。安装目录必须为空或带有匹配卸载记录的本产品目录，更新时要求先退出应用。

卸载程序从独立临时副本运行，核对产品标记与卸载记录后将程序目录和归属本应用的快捷方式移入回收站。卸载完成后，正在运行的临时卸载副本保留在 Windows 临时目录，交由系统存储管理清理，不影响软件卸载。

构建和文件完整性检查不替代真实 Windows 安装、升级、运行库 UAC、卸载及高 DPI 操作验收。


可在 Windows 构建机器上执行安装包的隔离自检：

```powershell
$process = Start-Process -FilePath ".\build\windows-installer\报销单助手-安装程序-1.27.exe" -ArgumentList @('--self-check', 'C:\Temp\installer-check.json') -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Installer payload self-check failed" }
Get-Content C:\Temp\installer-check.json
```

此模式只将嵌入载荷释放到随机 Windows 临时目录并逐文件检查路径、大小和 SHA-256，再检查主程序头、随包运行库版本元数据及受保护目录拒绝规则；不读写注册表、不安装运行库、不执行安装或卸载、不访问用户项目和密钥。测试文件保留。
