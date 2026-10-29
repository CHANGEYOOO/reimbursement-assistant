using System.Diagnostics;
using System.Net;
using System.Text.RegularExpressions;

namespace ReimburseApp;

public sealed class MailDetailPanel : UserControl
{
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TextBox _body = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill };
    private readonly FlowLayoutPanel _links = new() { Dock = DockStyle.Bottom, Height = 150, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = false };
    private readonly Label _header = new() { Dock = DockStyle.Top, Height = 95, AutoEllipsis = true };
    public event EventHandler? CloseRequested;
    public MailDetailPanel()
    {
        Dock = DockStyle.Fill; Padding = new Padding(8);
        var close = new Button { Text = "收起邮件", Dock = DockStyle.Top };
        close.Click += (_, _) => CloseRequested?.Invoke(this, EventArgs.Empty);
        Controls.Add(_body); Controls.Add(_links); Controls.Add(_header); Controls.Add(close);
    }
    public async Task LoadAsync(MailboxManualNotice notice)
    {
        _header.Text = $"{notice.Subject}\n{notice.Sender}\n收件时间：{notice.ReceivedAt.LocalDateTime:yyyy-MM-dd HH:mm}";
        _body.Text = "正在按需读取正文…";
        try
        {
            var detail = await MailService.FetchDetailAsync(notice, _lifetime.Token);
            if (IsDisposed) return;
            _body.Text = detail.Body;
            _links.Controls.Add(new Label { Text = "以下为邮件中的外部链接，未经验证：", AutoSize = true });
            foreach (var uri in detail.Links)
            {
                var link = new LinkLabel { Text = uri.AbsoluteUri, AutoSize = true, MaximumSize = new Size(600, 0) };
                link.LinkClicked += (_, _) => { if (MessageBox.Show(this, "使用浏览器打开以下网址？\n" + uri.AbsoluteUri, "外部链接", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes) Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); };
                _links.Controls.Add(link);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (!IsDisposed) _body.Text = "正文读取失败：" + ex.Message; }
    }
    protected override void Dispose(bool disposing) { if (disposing) { _lifetime.Cancel(); _lifetime.Dispose(); } base.Dispose(disposing); }
}
