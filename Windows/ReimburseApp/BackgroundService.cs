using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace ReimburseApp;

public sealed class BackgroundService : IDisposable
{
    private readonly InvoiceRepository _repository;
    private readonly NotifyIcon _tray;
    private readonly ToolStripMenuItem _syncMenu;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _syncCancellation;
    private Task? _syncTask;
    private bool _disposed;
    private bool _cacheCleanupPaused;
    private MailboxState? _state;
    public Action? OpenSettings { get; set; }
    public event EventHandler? ExitRequested;
    public event EventHandler? StatusChanged;
    public bool Syncing { get; private set; }
    public string Status { get; private set; } = "连接 QQ 邮箱后，新发票将自动下载并识别。";
    public DateTimeOffset? LastSyncAt => _state?.LastSyncAt;
    public IReadOnlyList<MailboxManualNotice> ManualMessages => _state?.ManualMessages ?? [];

    public BackgroundService(InvoiceRepository repository, Action openMain, Action openInbox)
    {
        _repository = repository;
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开报销单助手", null, (_, _) => openMain());
        menu.Items.Add("打开发票箱", null, (_, _) => openInbox());
        _syncMenu = new ToolStripMenuItem("立即同步", null, async (_, _) => await SyncAsync());
        menu.Items.Add(_syncMenu);
        menu.Items.Add("设置…", null, (_, _) => OpenSettings?.Invoke());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => ExitRequested?.Invoke(this, EventArgs.Empty));
        _tray = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Text = "报销单助手", Visible = true, ContextMenuStrip = menu
        };
        _tray.DoubleClick += (_, _) => openMain();
        _tray.BalloonTipClicked += (_, _) => openInbox();
        _timer = new System.Windows.Forms.Timer { Interval = 300_000 };
        _timer.Tick += async (_, _) =>
        {
            if (AppSettings.Current.MailEnabled) await SyncAsync();
            await MaintainCacheAsync();
        };
    }

    public async Task StartAsync()
    {
        _timer.Start();
        if (AppSettings.Current.MailEnabled) await SyncAsync();
        await MaintainCacheAsync();
    }

    public Task SyncAsync()
    {
        if (_disposed) return Task.CompletedTask;
        if (_syncTask is { IsCompleted: false }) return _syncTask;
        _syncTask = PerformSyncAsync();
        return _syncTask;
    }

    public async Task SettingsChangedAsync()
    {
        _syncCancellation?.Cancel();
        if (_syncTask is { IsCompleted: false }) await _syncTask;
        _cacheCleanupPaused = false;
        SetStatus(AppSettings.Current.MailEnabled ? "邮箱配置已保存，正在同步…" : "自动收集已关闭，已有发票保留。");
        if (AppSettings.Current.MailEnabled) await SyncAsync();
        await MaintainCacheAsync();
    }

    public void DismissNotice(string id)
    {
        if (_state == null) return;
        var previous = _state.ManualMessages.ToList();
        _state.ManualMessages.RemoveAll(item => item.Id == id);
        try { SaveState(_state); }
        catch { _state.ManualMessages = previous; throw; }
        StatusChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task PerformSyncAsync()
    {
        var settings = AppSettings.Current.Copy();
        if (!settings.MailEnabled) { SetStatus("请先在“设置 → QQ 邮箱”中连接并启用邮箱。"); return; }
        Syncing = true;
        _syncMenu.Enabled = false;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _syncCancellation = cancellation;
        var ct = cancellation.Token;
        var revision = AppSettings.Revision;
        var account = settings.MailAddress.Trim().ToLowerInvariant();
        bool Continue() => !_disposed && !ct.IsCancellationRequested && AppSettings.Revision == revision && AppSettings.Current.MailEnabled;
        try
        {
            var state = LoadState(account);
            _state = state;
            state.AutomaticDownloadsSince ??= DateTimeOffset.Now;
            SaveState(state);
            SetStatus("正在收集邮件并准备识别新发票…");
            var pendingHistorical = state.PendingHistorical;
            await MailService.FetchAsync(account, settings.MailPassword, settings.MailSince, state.Processed, async message =>
            {
                if (!Continue()) throw new OperationCanceledException(ct);
                var automatic = message.ReceivedAt >= state.AutomaticDownloadsSince.Value;
                if (message.Attachments.Count > 0)
                {
                    var before = _repository.Items.Count;
                    await _repository.RegisterMailAsync(message, automatic);
                    if (!automatic) state.PendingHistorical += Math.Max(0, _repository.Items.Count - before);
                }
                if (message.Attachments.Count == 0 && message.HasDownloadLink && !state.ManualMessages.Any(n => n.Id == message.Id))
                    state.ManualMessages.Add(new MailboxManualNotice(message.Id, message.Subject, message.Sender, message.ReceivedAt));
                state.Processed.Add(message.Id);
                SaveState(state);
            }, ct);
            if (!Continue()) throw new OperationCanceledException(ct);
            state.LastSyncAt = DateTimeOffset.Now;
            if (state.PendingHistorical > 0)
                Notify($"已收集 {state.PendingHistorical} 个历史附件", "历史邮件附件已整理到待下载附件，尚未检查是否为发票。点击查看。");
            pendingHistorical = state.PendingHistorical;
            state.PendingHistorical = 0;
            SaveState(state);
            SetStatus("正在自动下载并识别新附件…");
            var result = await _repository.DownloadPendingAsync(account, Continue);
            if (!Continue()) throw new OperationCanceledException(ct);
            if (result.accepted > 0) Notify($"收到 {result.accepted} 张新发票", "已自动下载、识别并加入发票箱。点击查看。");
            SetStatus($"同步完成，自动识别入箱 {result.accepted} 张发票。"
                + (pendingHistorical > 0 ? $"另有 {pendingHistorical} 个历史附件可按需下载。" : "")
                + (result.failed > 0 ? $"{result.failed} 个附件未下载完成，将在下次同步重试，也可手动下载。" : "")
                + (state.ManualMessages.Count > 0 ? $"有 {state.ManualMessages.Count} 封邮件需在 QQ 邮箱中查看下载链接。" : ""));
            await MaintainCacheAsync();
        }
        catch (OperationCanceledException) { SetStatus("同步已停止，已收集的信息保留。"); }
        catch (Exception ex) { SetStatus("邮箱同步未完成：" + SafeMessage(ex) + "；已收集的信息保留，可再次同步。"); }
        finally
        {
            Syncing = false;
            if (!_disposed) _syncMenu.Enabled = true;
            _syncCancellation = null;
            if (!_disposed) StatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task MaintainCacheAsync()
    {
        if (_disposed || _cacheCleanupPaused) return;
        try { await _repository.MaintainCacheAsync(); }
        catch (Exception ex)
        {
            _cacheCleanupPaused = true;
            SetStatus("缓存自动清理已停止：" + ex.Message + " 请检查权限后在缓存设置中手动重试。");
        }
    }

    private void Notify(string title, string body)
    {
        if (_disposed || !AppSettings.Current.NotificationsEnabled) return;
        _tray.ShowBalloonTip(8000, title, body, ToolTipIcon.Info);
    }
    private void SetStatus(string value)
    {
        Status = value;
        if (!_disposed) StatusChanged?.Invoke(this, EventArgs.Empty);
    }
    private static string SafeMessage(Exception exception) => exception switch
    {
        MailKit.Security.AuthenticationException => "QQ 邮箱拒绝登录，请检查 IMAP 服务和授权码",
        System.Net.Sockets.SocketException or IOException => "无法连接 QQ 邮箱，请检查网络、邮箱服务或本地文件权限",
        _ => exception.Message
    };
    private static string StatePath(string account)
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(account)));
        return Path.Combine(AppPaths.Root, "mail", hash + ".json");
    }
    private static MailboxState LoadState(string account)
    {
        var path = StatePath(account);
        if (!File.Exists(path)) return new MailboxState { Account = account };
        var state = JsonSerializer.Deserialize<MailboxState>(File.ReadAllText(path), AppSettings.JsonOptions)
            ?? throw new InvalidDataException("邮箱同步记录无法读取，原文件已保留。");
        if (!string.Equals(state.Account, account, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("邮箱同步记录与当前账户不符。");
        return state;
    }
    private static void SaveState(MailboxState state) => AppSettings.WriteJson(StatePath(state.Account), state);

    public static void SetStartupEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true)
            ?? throw new InvalidOperationException("无法访问 Windows 登录启动设置。");
        if (enabled) key.SetValue("ReimbursementAssistant", "\"" + Application.ExecutablePath + "\" --background");
        else if (key.GetValue("ReimbursementAssistant") != null) key.DeleteValue("ReimbursementAssistant", false);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _lifetime.Cancel();
        _timer.Stop();
        _timer.Dispose();
        _tray.Visible = false;
        _tray.ContextMenuStrip?.Dispose();
        _tray.Icon?.Dispose();
        _tray.Dispose();
        _lifetime.Dispose();
    }

    private sealed class MailboxState
    {
        public string Account { get; set; } = "";
        public DateTimeOffset? AutomaticDownloadsSince { get; set; }
        public DateTimeOffset? LastSyncAt { get; set; }
        public HashSet<string> Processed { get; set; } = [];
        public List<MailboxManualNotice> ManualMessages { get; set; } = [];
        public int PendingHistorical { get; set; }
    }
}
