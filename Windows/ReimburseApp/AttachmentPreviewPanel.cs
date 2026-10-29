using UglyToad.PdfPig;

namespace ReimburseApp;

public sealed class AttachmentPreviewPanel : UserControl
{
    private readonly Label _title = new() { Dock = DockStyle.Top, Height = 48, AutoEllipsis = true };
    private readonly Panel _scroll = new() { Dock = DockStyle.Fill, AutoScroll = true };
    private readonly PictureBox _picture = new() { SizeMode = PictureBoxSizeMode.StretchImage };
    private readonly Label _pageLabel = new() { AutoSize = true, Padding = new Padding(0, 7, 0, 0) };
    private readonly Button _previous = new() { Text = "上一页", AutoSize = true };
    private readonly Button _next = new() { Text = "下一页", AutoSize = true };
    private string? _path;
    private int _page;
    private int _pages = 1;
    private double _zoom = 1;
    private int _request;
    public event EventHandler? CloseRequested;
    public AttachmentPreviewPanel()
    {
        Dock = DockStyle.Fill; Padding = new Padding(8);
        var tools = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true };
        foreach (var text in new[] { "−", "适合宽度", "+", "收起" })
        {
            var button = new Button { Text = text, AutoSize = true };
            button.Click += (_, _) => { if (text == "收起") { Clear(); CloseRequested?.Invoke(this, EventArgs.Empty); } else { _zoom = text == "适合宽度" ? 1 : Math.Clamp(_zoom + (text == "+" ? .5 : -.5), 1, 8); Fit(); } };
            tools.Controls.Add(button);
        }
        _previous.Click += async (_, _) => { if (_page > 0) { _page--; await LoadPage(); } };
        _next.Click += async (_, _) => { if (_page + 1 < _pages) { _page++; await LoadPage(); } };
        tools.Controls.Add(_previous); tools.Controls.Add(_pageLabel); tools.Controls.Add(_next);
        _scroll.Controls.Add(_picture); _scroll.Resize += (_, _) => Fit();
        Controls.Add(_scroll); Controls.Add(tools); Controls.Add(_title);
    }
    public async Task ShowFileAsync(string path, string title)
    {
        Clear(); _path = path; _title.Text = title; _page = 0; _zoom = 1;
        _pages = 1;
        if (Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase))
        { using var document = PdfDocument.Open(path); _pages = document.NumberOfPages; }
        await LoadPage();
    }
    private async Task LoadPage()
    {
        if (_path == null) return;
        var request = ++_request; var path = _path; var page = _page;
        _previous.Enabled = false; _next.Enabled = false;
        try
        {
            var bytes = await Task.Run(() => InvoiceRecognition.PreviewPng(path, page));
            if (request != _request || IsDisposed) return;
            using var input = new MemoryStream(bytes); using var bitmap = new Bitmap(input);
            var old = _picture.Image; _picture.Image = new Bitmap(bitmap); old?.Dispose();
            _scroll.AutoScrollPosition = Point.Empty; Fit();
            _pageLabel.Text = $"{_page + 1} / {_pages}";
        }
        catch (Exception ex) { if (request == _request && !IsDisposed) _title.Text = "无法预览：" + ex.Message; }
        finally { if (request == _request && !IsDisposed) { _previous.Enabled = _page > 0; _next.Enabled = _page + 1 < _pages; } }
    }
    private void Fit()
    {
        if (_picture.Image == null) return;
        var width = Math.Max(40, (int)((_scroll.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 4) * _zoom));
        _picture.Size = new Size(width, Math.Max(1, (int)((double)_picture.Image.Height / _picture.Image.Width * width)));
    }
    public void Clear() { _request++; _path = null; var old = _picture.Image; _picture.Image = null; old?.Dispose(); }
    protected override void Dispose(bool disposing) { if (disposing) Clear(); base.Dispose(disposing); }
}
