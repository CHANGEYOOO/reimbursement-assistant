using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ReimburseApp;

public sealed class GitHubUpdatesPanel : UserControl
{
    private const string Repository = "https://github.com/CHANGEYOOO/reimbursement-assistant";
    private readonly Label _status = new() { AutoSize = true, MaximumSize = new Size(650, 0) };
    private readonly TextBox _notes = new() { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
    private readonly Button _check = new() { Text = "检查更新", AutoSize = true };
    private readonly Button _download = new() { Text = "打开下载页面", AutoSize = true, Enabled = false };
    private readonly CancellationTokenSource _lifetime = new();
    private Uri? _url;
    public GitHubUpdatesPanel()
    {
        Dock = DockStyle.Fill; Padding = new Padding(14);
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        top.Controls.Add(new Label { Text = "报销单助手 Windows " + Application.ProductVersion, AutoSize = true });
        _status.Text = "手动检查 GitHub 正式发布，不会自动安装。"; top.Controls.Add(_status);
        var actions = new FlowLayoutPanel { AutoSize = true }; actions.Controls.Add(_check); actions.Controls.Add(_download); top.Controls.Add(actions);
        Controls.Add(_notes); Controls.Add(top);
        _check.Click += async (_, _) => await CheckAsync();
        _download.Click += (_, _) => { if (_url != null) Process.Start(new ProcessStartInfo(_url.AbsoluteUri) { UseShellExecute = true }); };
    }
    internal static Version ParseVersion(string value) => GitHubReleaseRules.ParseVersion(value);
    public async Task CheckAsync()
    {
        _check.Enabled = false; _download.Enabled = false; _status.Text = "正在检查更新…";
        try
        {
            using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("ReimbursementAssistant-Windows/1.34");
            using var response = await client.GetAsync("https://api.github.com/repos/CHANGEYOOO/reimbursement-assistant/releases?per_page=30", HttpCompletionOption.ResponseHeadersRead, _lifetime.Token);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > 1_000_000) throw new InvalidDataException("更新信息过大。");
            using var stream = await response.Content.ReadAsStreamAsync(_lifetime.Token);
            using var bytes = new MemoryStream(); var buffer = new byte[8192]; int length;
            while ((length = await stream.ReadAsync(buffer, _lifetime.Token)) > 0) { if (bytes.Length + length > 1_000_000) throw new InvalidDataException("更新信息过大。"); await bytes.WriteAsync(buffer.AsMemory(0, length), _lifetime.Token); }
            using var json = JsonDocument.Parse(bytes.ToArray());
            var releases = json.RootElement.EnumerateArray().Where(r => !r.GetProperty("draft").GetBoolean() && !r.GetProperty("prerelease").GetBoolean()).Select(r => (Data: r, Version: ParseVersion(r.GetProperty("tag_name").GetString() ?? ""))).OrderByDescending(r => r.Version).ToList();
            if (releases.Count == 0) throw new InvalidDataException("尚无正式发布。");
            var release = releases[0]; var current = ParseVersion(Application.ProductVersion);
            _notes.Text = release.Data.GetProperty("body").GetString() ?? "";
            var asset = release.Data.GetProperty("assets").EnumerateArray().FirstOrDefault(a => { var name = (a.GetProperty("name").GetString() ?? "").ToLowerInvariant(); return name.EndsWith(".exe") && name.Contains("windows") && !name.Contains("arm"); });
            var target = asset.ValueKind == JsonValueKind.Undefined ? release.Data.GetProperty("html_url").GetString() : asset.GetProperty("browser_download_url").GetString();
            var uri = GitHubReleaseRules.DownloadUri(target);
            if (IsDisposed) return;
            _url = uri; _download.Enabled = true;
            _status.Text = release.Version > current ? "发现新版本 " + release.Version : "当前已是最新正式版本。";
        }
        catch (OperationCanceledException) { if (!IsDisposed) _status.Text = "检查已停止或超时。"; }
        catch (Exception ex) { if (!IsDisposed) _status.Text = "检查未完成：" + ex.Message; }
        finally { if (!IsDisposed) _check.Enabled = true; }
    }
    protected override void Dispose(bool disposing) { if (disposing) { _lifetime.Cancel(); _lifetime.Dispose(); } base.Dispose(disposing); }
}
