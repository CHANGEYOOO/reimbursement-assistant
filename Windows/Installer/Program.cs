using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.VisualBasic.FileIO;
using Microsoft.Win32;

namespace ReimburseInstaller;

internal static class Program
{
    internal const string ProductId = "CHANGEYOOO.ReimbursementAssistant";
    internal const string AppName = "报销单助手";
    internal const string AppExe = "报销单助手.exe";
    internal const string UninstallerExe = "卸载报销单助手.exe";
    internal const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ReimbursementAssistant";
    internal static readonly string DataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);

    [STAThread] private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        try
        {
            if (args.Length == 0 && Path.GetFileName(Environment.ProcessPath) == UninstallerExe) args = ["--uninstall"];
            if (args.Length == 1 && args[0] == "--uninstall")
            {
                var location = Path.GetDirectoryName(Environment.ProcessPath!)!;
                ValidateInstalledDirectory(location);
                if (MessageBox.Show("卸载报销单助手？\n\n仅移除程序、快捷方式和登录启动项，报销项目、截图、发票和设置都会保留。", "卸载报销单助手", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
                EnsureAppStopped(location);
                // shortcut: the running temporary uninstaller is left for Windows storage cleanup.
                var temp = Path.Combine(Path.GetTempPath(), "ReimbursementUninstall-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(temp);
                File.WriteAllText(Path.Combine(temp, "cleanup.id"), ProductId);
                var copy = Path.Combine(temp, UninstallerExe);
                File.Copy(Environment.ProcessPath!, copy);
                var start = new ProcessStartInfo(copy) { UseShellExecute = false };
                start.ArgumentList.Add("--uninstall-run"); start.ArgumentList.Add(location);
                start.ArgumentList.Add(Environment.ProcessId.ToString());
                _ = Process.Start(start) ?? throw new IOException("无法启动卸载程序。");
                return;
            }
            if (args.Length == 3 && args[0] == "--uninstall-run")
            {
                if (int.TryParse(args[2], out var parentPid))
                    try { Process.GetProcessById(parentPid).WaitForExit(15_000); } catch (ArgumentException) { }
                Uninstall(args[1]);
                MessageBox.Show("报销单助手已卸载。\n\n你的报销项目、发票和设置已保留，重新安装后可以继续使用。", "卸载完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Application.Run(new InstallerForm());
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message + "\n\n操作已停止，已有报销数据不会被清理。", "操作未完成", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    internal static string NormalizeTarget(string path)
    {
        var target = Path.GetFullPath(path.Trim()).TrimEnd(Path.DirectorySeparatorChar);
        if (Path.GetFileName(target) != AppName || string.Equals(target, DataDirectory, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(target, Path.GetPathRoot(target)?.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("请选择独立的“报销单助手”程序文件夹，不要选择项目或设置数据目录。");
        var root = Path.GetPathRoot(target);
        if (string.IsNullOrEmpty(root) || root.StartsWith(@"\\")) throw new InvalidOperationException("请安装到当前电脑的本地磁盘。");
        for (var current = new DirectoryInfo(target); current != null; current = current.Parent)
            if (current.Exists && (current.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("安装位置或上级目录是目录链接，请选择普通本地文件夹。");
        if (Directory.Exists(target))
        {
            if ((File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0) throw new IOException("安装位置是目录链接，请选择普通文件夹。");
            if (Directory.EnumerateFileSystemEntries(target).Any()) ValidateInstalledDirectory(target);
        }
        return target;
    }

    internal static void EnsureAppStopped(string target)
    {
        var expected = Path.Combine(target, AppExe);
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(AppExe)))
        {
            using (process)
            {
                try
                {
                    if (string.Equals(process.MainModule?.FileName, expected, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("报销单助手仍在运行。请先从右下角托盘菜单选择“退出”，再继续。");
                }
                catch (System.ComponentModel.Win32Exception) { throw new IOException("无法确认报销单助手是否已经退出，请退出其他版本后重试。"); }
            }
        }
    }

    internal static bool HasVisualCppRuntime()
    {
        using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var runtime = machine.OpenSubKey(@"SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64");
        if (runtime?.GetValue("Installed") is not int installed || installed != 1) return false;
        var major = Convert.ToInt32(runtime.GetValue("Major") ?? 0);
        var minor = Convert.ToInt32(runtime.GetValue("Minor") ?? 0);
        return major > 14 || major == 14 && minor >= 29;
    }

    internal static async Task<string> ExtractVerifiedPayloadAsync(string target, Action<int, string> progress)
    {
        var parent = Path.GetDirectoryName(target)!;
        Directory.CreateDirectory(parent);
        var stage = Path.Combine(parent, ".ReimbursementInstall-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("ReimburseInstaller.payload.zip")
                ?? throw new IOException("安装包缺少程序文件，请重新下载完整安装包。");
            using var archive = new ZipArchive(source, ZipArchiveMode.Read);
            var manifestEntry = archive.GetEntry("manifest.json") ?? throw new InvalidDataException("安装包缺少完整性清单。");
            if (manifestEntry.Length > 2_000_000) throw new InvalidDataException("安装清单过大。");
            Dictionary<string, string> manifest;
            using (var stream = manifestEntry.Open()) manifest = await JsonSerializer.DeserializeAsync<Dictionary<string, string>>(stream) ?? throw new InvalidDataException("安装清单无效。");
            var entries = archive.Entries.Where(e => !e.FullName.EndsWith('/') && e.FullName != "manifest.json").ToList();
            if (entries.Count == 0 || entries.Count > 2000 || entries.Sum(e => e.Length) > 2_000_000_000L || !manifest.ContainsKey(AppExe))
                throw new InvalidDataException("安装包文件数量、大小或主程序不符合要求。");
            if (manifest.Count != entries.Count) throw new InvalidDataException("安装清单与文件数量不一致。");
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in entries)
            {
                var name = entry.FullName.Replace('\\', '/');
                if (Path.IsPathRooted(name) || name.Contains(':') || name.Split('/').Any(p => (p is "." or ".." or "") || p.EndsWith('.') || p.EndsWith(' ') || p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) ||
                    !names.Add(name) || !manifest.TryGetValue(name, out var expected) || expected.Length != 64 ||
                    ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                    throw new InvalidDataException("安装包包含无效或重复路径。");
                var destination = Path.GetFullPath(Path.Combine(stage, name));
                if (!destination.StartsWith(stage + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装路径越界。");
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                using (var input = entry.Open())
                using (var output = File.Create(destination)) await input.CopyToAsync(output);
                using (var file = File.OpenRead(destination))
                {
                    var actual = Convert.ToHexString(await SHA256.HashDataAsync(file));
                    if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装文件校验失败，请重新下载安装包。");
                }
                progress(10 + names.Count * 65 / entries.Count, "正在验证程序文件…");
            }
            return stage;
        }
        catch { RecycleDirectory(stage); throw; }
    }

    internal static async Task InstallRuntimeAsync(string stage, bool consent)
    {
        if (HasVisualCppRuntime()) return;
        if (!consent) throw new InvalidOperationException("本机缺少截图识别需要的 Microsoft Visual C++ 运行库。请勾选安装运行库后重试。");
        var runtime = Path.Combine(stage, ".installer", "vc_redist.x64.exe");
        if (!File.Exists(runtime)) throw new IOException("安装包未包含 Microsoft Visual C++ 运行库，无法完成安装。请获取完整安装包。");
        var start = new ProcessStartInfo(runtime) { UseShellExecute = true, Verb = "runas", Arguments = "/install /quiet /norestart" };
        using var process = Process.Start(start) ?? throw new IOException("无法启动 Microsoft Visual C++ 运行库安装。");
        await process.WaitForExitAsync();
        if (process.ExitCode is not (0 or 3010 or 1638) || !HasVisualCppRuntime())
            throw new IOException("Microsoft Visual C++ 运行库未安装成功。请完成或重启电脑后再安装本软件。");
    }

    internal static void CompleteInstallation(string stage, string target, bool desktop)
    {
        EnsureAppStopped(target);
        var runtimeFolder = Path.Combine(stage, ".installer");
        if (Directory.Exists(runtimeFolder)) RecycleDirectory(runtimeFolder);
        var backup = target + ".previous-" + Guid.NewGuid().ToString("N");
        var hadExisting = Directory.Exists(target);
        if (hadExisting) Directory.Move(target, backup);
        try { Directory.Move(stage, target); }
        catch { if (hadExisting && !Directory.Exists(target)) Directory.Move(backup, target); throw; }
        var uninstaller = Path.Combine(target, UninstallerExe);
        File.Copy(Environment.ProcessPath!, uninstaller, true);
        var marker = new InstallMarker { ProductId = ProductId, InstallLocation = target, DesktopShortcut = desktop };
        File.WriteAllText(Path.Combine(target, "installation.json"), JsonSerializer.Serialize(marker));
        var shortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", AppName, AppName + ".lnk");
        CreateShortcut(shortcut, target);
        var desktopPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), AppName + ".lnk");
        if (desktop) CreateShortcut(desktopPath, target);
        using var registry = Registry.CurrentUser.CreateSubKey(UninstallKey, true) ?? throw new IOException("无法写入卸载信息。");
        registry.SetValue("DisplayName", AppName);
        registry.SetValue("DisplayVersion", "1.27.0");
        registry.SetValue("Publisher", "CHANGEYOOO");
        registry.SetValue("InstallLocation", target);
        registry.SetValue("DisplayIcon", Path.Combine(target, AppExe));
        registry.SetValue("UninstallString", "\"" + uninstaller + "\" --uninstall");
        registry.SetValue("NoModify", 1, RegistryValueKind.DWord);
        registry.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        registry.SetValue("EstimatedSize", (int)Math.Min(int.MaxValue, Directory.EnumerateFiles(target, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length) / 1024), RegistryValueKind.DWord);
        if (hadExisting) RecycleDirectory(backup);
    }

    private static void CreateShortcut(string shortcutPath, string target)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(shortcutPath)!);
        var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Windows 快捷方式服务不可用。");
        dynamic shell = Activator.CreateInstance(type)!;
        dynamic shortcut = shell.CreateShortcut(shortcutPath);
        try
        {
            shortcut.TargetPath = Path.Combine(target, AppExe); shortcut.WorkingDirectory = target;
            shortcut.IconLocation = Path.Combine(target, AppExe); shortcut.Description = AppName; shortcut.Save();
        }
        finally { Marshal.FinalReleaseComObject(shortcut); Marshal.FinalReleaseComObject(shell); }
    }

    private static void ValidateInstalledDirectory(string location)
    {
        var full = Path.GetFullPath(location).TrimEnd(Path.DirectorySeparatorChar);
        if (full.Equals(DataDirectory, StringComparison.OrdinalIgnoreCase) || Path.GetFileName(full) != AppName ||
            (File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0) throw new IOException("不能将此目录识别为报销单助手程序目录。");
        var markerFile = Path.Combine(full, "installation.json");
        if (!File.Exists(markerFile)) throw new IOException("所选文件夹已有其他文件。请选择空的“报销单助手”文件夹，避免覆盖资料。");
        var marker = JsonSerializer.Deserialize<InstallMarker>(File.ReadAllText(markerFile));
        if (marker?.ProductId != ProductId || !string.Equals(marker.InstallLocation, full, StringComparison.OrdinalIgnoreCase))
            throw new IOException("安装目录标记不匹配，操作已停止。");
        using var registry = Registry.CurrentUser.OpenSubKey(UninstallKey);
        if (!string.Equals(registry?.GetValue("InstallLocation") as string, full, StringComparison.OrdinalIgnoreCase)) throw new IOException("安装目录与 Windows 卸载记录不一致，操作已停止。");
    }

    private static void Uninstall(string location)
    {
        ValidateInstalledDirectory(location);
        EnsureAppStopped(location);
        var shortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", AppName, AppName + ".lnk");
        RemoveShortcut(shortcut, location);
        RemoveShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), AppName + ".lnk"), location);
        RecycleDirectory(location);
        using (var startup = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
        {
            var entry = startup?.GetValue("ReimbursementAssistant") as string;
            if (entry?.StartsWith("\"" + Path.Combine(location, AppExe) + "\"", StringComparison.OrdinalIgnoreCase) == true) startup!.DeleteValue("ReimbursementAssistant", false);
        }
        Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
    }
    private static void RemoveShortcut(string shortcutPath, string target)
    {
        if (!File.Exists(shortcutPath)) return;
        var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Windows 快捷方式服务不可用。");
        dynamic shell = Activator.CreateInstance(type)!;
        dynamic shortcut = shell.CreateShortcut(shortcutPath);
        try
        {
            if (string.Equals((string)shortcut.TargetPath, Path.Combine(target, AppExe), StringComparison.OrdinalIgnoreCase))
                FileSystem.DeleteFile(shortcutPath, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin, UICancelOption.ThrowException);
        }
        finally { Marshal.FinalReleaseComObject(shortcut); Marshal.FinalReleaseComObject(shell); }
    }
    internal static void RecycleDirectory(string path) => FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin, UICancelOption.ThrowException);

    private sealed class InstallMarker
    {
        public string ProductId { get; set; } = "";
        public string InstallLocation { get; set; } = "";
        public bool DesktopShortcut { get; set; }
    }
}

internal sealed class InstallerForm : Form
{
    private readonly TextBox _directory = new() { Width = 500 };
    private readonly CheckBox _desktop = new() { Text = "创建桌面快捷方式", AutoSize = true, Checked = true };
    private readonly CheckBox _runtime = new() { Text = "本机缺少识别运行库时，允许安装 Microsoft Visual C++ 运行库", AutoSize = true, Checked = true };
    private readonly ProgressBar _progress = new() { Width = 650, Height = 20 };
    private readonly Label _status = new() { AutoSize = true, MaximumSize = new Size(650, 0) };
    private readonly Button _install = new() { Text = "开始安装", Width = 130, Height = 36 };
    private readonly Button _browse = new() { Text = "浏览…", AutoSize = true };
    private bool _working;
    private string? _installedDirectory;
    public InstallerForm()
    {
        Text = "安装报销单助手 1.27";
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new Font("Microsoft YaHei UI", 10);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(720, 440); FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
        var body = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
        body.Controls.Add(new Label { Text = "报销单助手", AutoSize = true, Font = new Font(Font.FontFamily, 21, FontStyle.Bold), Margin = new Padding(0, 0, 0, 12) });
        body.Controls.Add(new Label { Text = "将订单截图整理为报销单，自动收集与管理发票。\n安装程序仅安装软件，不会清理已有报销项目或设置。", AutoSize = true, Margin = new Padding(0, 0, 0, 14) });
        body.Controls.Add(new Label { Text = "安装位置", AutoSize = true });
        _directory.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", Program.AppName);
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        row.Controls.Add(_directory); row.Controls.Add(_browse); body.Controls.Add(row);
        _browse.Click += (_, _) => { using var dialog = new FolderBrowserDialog { Description = "选择安装位置（会自动创建报销单助手文件夹）" }; if (dialog.ShowDialog(this) == DialogResult.OK) _directory.Text = Path.Combine(dialog.SelectedPath, Program.AppName); };
        body.Controls.Add(_desktop); body.Controls.Add(_runtime);
        body.Controls.Add(_progress); body.Controls.Add(_status); body.Controls.Add(_install); Controls.Add(body);
        _install.Click += async (_, _) => await InstallAsync();
        FormClosing += (_, e) => { if (_working) { e.Cancel = true; _status.Text = "正在安装，请等待完成后关闭。"; } };
    }
    private async Task InstallAsync()
    {
        if (_installedDirectory != null) { Process.Start(new ProcessStartInfo(Path.Combine(_installedDirectory, Program.AppExe)) { UseShellExecute = true }); Close(); return; }
        if (_working) return;
        string? stage = null;
        _working = true; _install.Enabled = _browse.Enabled = _directory.Enabled = _desktop.Enabled = _runtime.Enabled = false;
        try
        {
            var target = Program.NormalizeTarget(_directory.Text);
            Program.EnsureAppStopped(target);
            _status.Text = "正在检查安装包…";
            stage = await Program.ExtractVerifiedPayloadAsync(target, (value, text) => { _progress.Value = value; _status.Text = text; });
            _status.Text = "正在检查识别运行库…"; _progress.Value = 78;
            await Program.InstallRuntimeAsync(stage, _runtime.Checked);
            _status.Text = "正在完成安装…"; _progress.Value = 90;
            Program.CompleteInstallation(stage, target, _desktop.Checked);
            _installedDirectory = target; _progress.Value = 100;
            _status.Text = "安装完成。可从桌面或开始菜单打开，卸载入口位于 Windows 设置的“应用”中。";
            _install.Text = "立即打开";
        }
        catch (Exception ex)
        {
            var detail = ex.Message;
            if (stage != null && Directory.Exists(stage))
                try { Program.RecycleDirectory(stage); }
                catch (Exception cleanup) { detail += "\n安装暂存文件无法移入回收站：" + cleanup.Message; }
            _status.Text = "安装未完成：" + detail;
            MessageBox.Show(this, _status.Text + "\n已有报销项目和设置保留。", "安装未完成", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { _working = false; _install.Enabled = true; if (_installedDirectory == null) _browse.Enabled = _directory.Enabled = _desktop.Enabled = _runtime.Enabled = true; }
    }
}
