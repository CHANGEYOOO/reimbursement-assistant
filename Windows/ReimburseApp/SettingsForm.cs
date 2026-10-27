using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace ReimburseApp;

public sealed class SettingsForm : Form
{
    private readonly InvoiceRepository? _repository;
    private readonly AppSettings _original;
    private readonly ComboBox _provider = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 280 };
    private readonly CheckBox _aiEnabled = new() { Text = "启用 AI 辅助识别", AutoSize = true };
    private readonly TextBox _endpoint = new() { Width = 560 };
    private readonly TextBox _model = new() { Width = 560 };
    private readonly TextBox _apiKey = new() { Width = 560, UseSystemPasswordChar = true, PlaceholderText = "留空保留当前服务商已保存的密钥" };
    private readonly CheckBox _mailEnabled = new() { Text = "启用自动收集发票", AutoSize = true };
    private readonly TextBox _address = new() { Width = 560 };
    private readonly TextBox _mailCode = new() { Width = 560, UseSystemPasswordChar = true, PlaceholderText = "留空保留此邮箱已保存的授权码" };
    private readonly DateTimePicker _since = new() { Width = 220, Format = DateTimePickerFormat.Custom, CustomFormat = "yyyy-MM-dd", MaxDate = DateTime.Today };
    private readonly CheckBox _notifications = new() { Text = "收到新发票时通知我", AutoSize = true };
    private readonly CheckBox _startup = new() { Text = "登录 Windows 后自动启动", AutoSize = true };
    private readonly NumericUpDown _cacheLimit = new() { Width = 180, Minimum = 0.01M, Maximum = 1_000_000, DecimalPlaces = 2 };
    private readonly Label _cacheUsed = new() { AutoSize = true };
    private readonly Label _message = new() { AutoSize = true, MaximumSize = new Size(710, 0), ForeColor = Color.DarkSlateGray };
    private readonly Button _save = new() { Text = "保存设置", AutoSize = true };
    private bool _loading = true;
    private bool _busy;
    public bool Saved { get; private set; }
    public event EventHandler? SettingsSaved;

    public SettingsForm(string tessdataDirectory, InvoiceRepository? repository = null)
    {
        _repository = repository;
        _original = AppSettings.Current.Copy();
        Text = "设置";
        Font = new Font("Microsoft YaHei UI", 10);
        Size = new Size(780, 700);
        MinimumSize = new Size(730, 640);
        StartPosition = FormStartPosition.CenterParent;
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Padding = new Padding(14) };
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 45));
        Controls.Add(root);
        var tabs = new TabControl { Dock = DockStyle.Fill };
        root.Controls.Add(tabs, 0, 0);
        tabs.TabPages.Add(AiTab()); tabs.TabPages.Add(MailTab()); tabs.TabPages.Add(BackgroundTab()); tabs.TabPages.Add(CacheTab());
        root.Controls.Add(_message, 0, 1);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, WrapContents = false };
        _save.Click += async (_, _) => await SaveAsync();
        var cancel = new Button { Text = "关闭", AutoSize = true };
        cancel.Click += (_, _) => Close();
        buttons.Controls.Add(_save); buttons.Controls.Add(cancel);
        root.Controls.Add(buttons, 0, 2);
        _provider.Items.AddRange(["DeepSeek", "阿里百炼", "自定义"]);
        _provider.SelectedItem = _original.AiProvider;
        if (_provider.SelectedIndex < 0) _provider.SelectedIndex = 0;
        _endpoint.Text = _original.AiEndpoint; _model.Text = _original.AiModel; _aiEnabled.Checked = _original.AiEnabled;
        _address.Text = _original.MailAddress; _mailEnabled.Checked = _original.MailEnabled;
        _since.Value = _original.MailSince.LocalDateTime.Date > DateTime.Today ? DateTime.Today : _original.MailSince.LocalDateTime.Date;
        _notifications.Checked = _original.NotificationsEnabled; _startup.Checked = _original.StartupEnabled;
        _cacheLimit.Value = Math.Clamp((decimal)_original.CacheLimitMb, _cacheLimit.Minimum, _cacheLimit.Maximum);
        _provider.SelectedIndexChanged += (_, _) => ProviderChanged();
        _notifications.CheckedChanged += (_, _) => SaveImmediate(startup: false);
        _startup.CheckedChanged += (_, _) => SaveImmediate(startup: true);
        _loading = false;
        RefreshCacheUsage();
    }

    private TabPage AiTab()
    {
        var (tab, body) = Page("AI 辅助识别");
        body.Controls.Add(Help("不开启 AI 也能正常使用。开启后，本地无法确定的金额、日期和用途会自动交给你配置的 AI；仅发送识别文字，不上传截图原图。"));
        body.Controls.Add(_aiEnabled);
        Field(body, "服务商", _provider); Field(body, "接口地址（HTTPS）", _endpoint); Field(body, "模型名称", _model); Field(body, "API Key", _apiKey);
        body.Controls.Add(Help("密钥使用 Windows 系统加密保存。AI 服务可能收费，请确认模型和服务地域与密钥一致。"));
        var test = new Button { Text = "测试连接", AutoSize = true };
        test.Click += async (_, _) => await RunAsync(test, async () =>
        {
            var settings = Draft();
            AppSettings.ValidateAi(settings.AiEndpoint, settings.AiModel, settings.ApiKey);
            await TestAiAsync(settings);
            _message.Text = "AI 连接成功。测试没有上传订单截图；保存后生效。";
        });
        body.Controls.Add(test);
        return tab;
    }

    private TabPage MailTab()
    {
        var (tab, body) = Page("QQ 邮箱");
        body.Controls.Add(Help("在 QQ 邮箱开启 IMAP 服务并生成授权码后填写。授权码不是 QQ 登录密码，只在本机加密保存。"));
        body.Controls.Add(_mailEnabled);
        Field(body, "QQ 邮箱地址", _address); Field(body, "邮箱授权码", _mailCode); Field(body, "从这个日期开始收集", _since);
        body.Controls.Add(Help("软件运行且电脑联网、未休眠时，每 5 分钟检查一次。新版首次同步后收到的新发票附件自动下载并识别；历史附件按需下载。不会改变邮件已读状态或删除邮件。"));
        body.Controls.Add(Help("只含下载链接的邮件会提醒你到 QQ 邮箱中下载后导入，不直接同步 QQ 邮箱自带的发票助手。"));
        var test = new Button { Text = "测试连接", AutoSize = true };
        test.Click += async (_, _) => await RunAsync(test, async () =>
        {
            var settings = Draft();
            await MailService.TestAsync(settings.MailAddress, settings.MailPassword);
            _message.Text = "邮箱连接成功。测试没有下载附件，保存并启用后开始收集。";
        });
        body.Controls.Add(test);
        return tab;
    }

    private TabPage BackgroundTab()
    {
        var (tab, body) = Page("后台与通知");
        body.Controls.Add(_notifications);
        body.Controls.Add(Help("新发票按批汇总通知，点击通知打开发票箱。关闭通知不会停止收票。若收不到通知，请检查 Windows 通知设置和勿扰模式。"));
        body.Controls.Add(_startup);
        body.Controls.Add(Help("这两个开关即时保存。关闭主窗口会隐藏到右下角托盘并继续收票；请从托盘菜单选择“退出”停止运行。登录启动需要先将软件安装到固定位置，电脑仍需联网且未休眠。"));
        return tab;
    }

    private TabPage CacheTab()
    {
        var (tab, body) = Page("缓存管理");
        body.Controls.Add(_cacheUsed);
        Field(body, "缓存大小上限（MB）", _cacheLimit);
        body.Controls.Add(Help("默认 200 MB，可自行修改。超出上限后优先清理最久未使用、可从邮箱重新下载的文件；正在使用的附件稍后处理。项目副本、手动导入和已导出文件保留。清理后不会反复自动下载，需要时再取回。"));
        var apply = new Button { Text = "保存上限并清理超出部分", AutoSize = true, Enabled = _repository != null };
        apply.Click += async (_, _) => await RunAsync(apply, async () =>
        {
            var next = AppSettings.Current.Copy(); next.CacheLimitMb = (double)_cacheLimit.Value; AppSettings.Replace(next);
            Saved = true; SettingsSaved?.Invoke(this, EventArgs.Empty);
            await _repository!.RetryCacheCleanupAsync(); RefreshCacheUsage(); _message.Text = "缓存上限已保存，已检查超出部分。";
        });
        var clear = new Button { Text = "清理全部可恢复缓存", AutoSize = true, Enabled = _repository != null };
        clear.Click += async (_, _) =>
        {
            if (MessageBox.Show(this, "仅将可从邮箱重新下载的缓存移入回收站，保留发票记录、项目副本、手动导入和已导出文件。继续吗？", "清理缓存", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            await RunAsync(clear, async () => { await _repository!.MaintainCacheAsync(true); RefreshCacheUsage(); _message.Text = "可恢复缓存已清理，记录和项目文件保留。"; });
        };
        var retry = new Button { Text = "重试自动清理", AutoSize = true, Enabled = _repository != null };
        retry.Click += async (_, _) => await RunAsync(retry, async () => { await _repository!.RetryCacheCleanupAsync(); RefreshCacheUsage(); _message.Text = "已恢复自动清理并检查缓存上限。"; });
        body.Controls.Add(apply); body.Controls.Add(clear); body.Controls.Add(retry);
        body.Controls.Add(Help("缓存清理使用 Windows 回收站。要实际释放磁盘空间，请自行检查并清空回收站；如果邮箱原件被删除，已清理的附件可能无法重新下载，重要资料请另行备份。"));
        return tab;
    }

    private AppSettings Draft()
    {
        var provider = _provider.SelectedItem?.ToString() ?? "DeepSeek";
        var address = _address.Text.Trim().ToLowerInvariant();
        return new AppSettings
        {
            AiEnabled = _aiEnabled.Checked, AiProvider = provider, AiEndpoint = _endpoint.Text.Trim(), AiModel = _model.Text.Trim(),
            ApiKey = string.IsNullOrWhiteSpace(_apiKey.Text) ? provider == _original.AiProvider ? _original.ApiKey : "" : _apiKey.Text.Trim(),
            MailEnabled = _mailEnabled.Checked, MailAddress = address,
            MailPassword = string.IsNullOrWhiteSpace(_mailCode.Text) ? string.Equals(address, _original.MailAddress, StringComparison.OrdinalIgnoreCase) ? _original.MailPassword : "" : _mailCode.Text.Trim(),
            MailSince = new DateTimeOffset(_since.Value.Date), NotificationsEnabled = _notifications.Checked,
            StartupEnabled = _startup.Checked, CacheLimitMb = (double)_cacheLimit.Value
        };
    }
    private void ProviderChanged()
    {
        var provider = _provider.SelectedItem?.ToString() ?? "DeepSeek";
        if (provider == _original.AiProvider) { _endpoint.Text = _original.AiEndpoint; _model.Text = _original.AiModel; }
        else if (provider == "DeepSeek") { _endpoint.Text = "https://api.deepseek.com/chat/completions"; _model.Text = "deepseek-flash"; }
        else if (provider == "阿里百炼") { _endpoint.Text = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"; _model.Text = "qwen-plus"; }
        else { _endpoint.Text = ""; _model.Text = ""; }
        _apiKey.Clear();
    }
    private void SaveImmediate(bool startup)
    {
        if (_loading || _busy) return;
        var previous = AppSettings.Current;
        var next = previous.Copy();
        if (startup) next.StartupEnabled = _startup.Checked; else next.NotificationsEnabled = _notifications.Checked;
        try
        {
            if (startup) BackgroundService.SetStartupEnabled(next.StartupEnabled);
            try { AppSettings.Replace(next); }
            catch { if (startup) BackgroundService.SetStartupEnabled(previous.StartupEnabled); throw; }
            Saved = true; SettingsSaved?.Invoke(this, EventArgs.Empty);
            _message.Text = startup ? "登录启动设置已保存。" : next.NotificationsEnabled ? "新发票通知已开启。" : "通知已关闭，后台收票不受影响。";
        }
        catch (Exception ex)
        {
            _loading = true; _startup.Checked = previous.StartupEnabled; _notifications.Checked = previous.NotificationsEnabled; _loading = false;
            _message.Text = "设置失败：" + ex.Message;
        }
    }
    private async Task SaveAsync()
    {
        await RunAsync(_save, async () =>
        {
            var settings = Draft();
            AppSettings.Replace(settings);
            Saved = true; SettingsSaved?.Invoke(this, EventArgs.Empty);
            if (_repository != null) await _repository.MaintainCacheAsync();
            DialogResult = DialogResult.OK; Close();
        });
    }
    private async Task RunAsync(Button button, Func<Task> action)
    {
        if (_busy) return;
        _busy = true; button.Enabled = false; _save.Enabled = false;
        try { await action(); }
        catch (Exception ex) { _message.Text = ex is HttpRequestException ? "无法连接 AI 服务，请检查网络与接口地址。" : ex.Message; }
        finally { _busy = false; if (!IsDisposed) { button.Enabled = true; _save.Enabled = true; } }
    }
    private void RefreshCacheUsage()
    {
        try { _cacheUsed.Text = _repository == null ? "打开项目后可查看缓存占用。" : $"当前可恢复缓存：{_repository.CacheBytes / 1_000_000D:0.##} MB"; }
        catch (Exception ex) { _cacheUsed.Text = "无法读取缓存占用：" + ex.Message; }
    }
    private static (TabPage Tab, FlowLayoutPanel Body) Page(string title)
    {
        var tab = new TabPage(title) { Padding = new Padding(12) };
        var body = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(6) };
        tab.Controls.Add(body); return (tab, body);
    }
    private static Label Help(string text) => new() { Text = text, AutoSize = true, MaximumSize = new Size(625, 0), Margin = new Padding(0, 8, 0, 12), ForeColor = Color.DimGray };
    private static void Field(FlowLayoutPanel body, string label, Control input)
    {
        body.Controls.Add(new Label { Text = label, AutoSize = true, Margin = new Padding(0, 8, 0, 3) }); body.Controls.Add(input);
    }
    private static async Task TestAiAsync(AppSettings settings)
    {
        using var handler = new HttpClientHandler { AllowAutoRedirect = false };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(45) };
        using var request = new HttpRequestMessage(HttpMethod.Post, settings.AiEndpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", settings.ApiKey);
        request.Content = new StringContent(JsonSerializer.Serialize(new { model = settings.AiModel, messages = new[] { new { role = "user", content = "请只回复 OK。" } }, max_tokens = 16, temperature = 0 }), Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"AI 服务返回 HTTP {(int)response.StatusCode}，请检查密钥、服务地址、模型或余额。");
        using var stream = await response.Content.ReadAsStreamAsync();
        var bytes = new byte[64 * 1024 + 1]; var count = 0;
        while (count < bytes.Length) { var read = await stream.ReadAsync(bytes.AsMemory(count)); if (read == 0) break; count += read; }
        if (count > 64 * 1024) throw new InvalidOperationException("AI 测试响应过长。");
        using var parsed = JsonDocument.Parse(bytes.AsMemory(0, count));
        if (!parsed.RootElement.TryGetProperty("choices", out var choices) || choices.GetArrayLength() == 0) throw new InvalidOperationException("AI 响应格式无效，请使用兼容 Chat Completions 的接口。");
    }
}
