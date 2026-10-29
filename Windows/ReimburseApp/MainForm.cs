using System.Drawing.Imaging;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using ImageMagick;

namespace ReimburseApp;

public sealed class MainForm : Form
{
    private static readonly string[] Categories = ["待分类", "交通", "餐食", "住宿", "道具采购", "其他"];
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".heic" };
    private readonly string _tessdataDirectory;
    private List<ExpenseRow> _expenses = [];
    private readonly Dictionary<Guid, RowControls> _controls = [];
    private readonly ProjectStore _store = new();
    private ProjectRecord _project = null!;
    private readonly ListBox _projects = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly Panel _host = new() { Dock = DockStyle.Fill };
    private readonly SplitContainer _orderSplit = new() { Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel2 };
    private readonly PictureBox _preview = new() { SizeMode = PictureBoxSizeMode.StretchImage };
    private readonly Panel _previewScroll = new() { Dock = DockStyle.Fill, AutoScroll = true };
    private double _previewZoom = 1;
    private readonly Label _previewTitle = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(8), Text = "点击一笔订单查看截图" };
    private readonly TextBox _search = new() { Width = 145, PlaceholderText = "搜索已填写金额" };
    private readonly CheckBox _onlyProblems = new() { Text = "只看待处理", AutoSize = true };
    private readonly Button _undoButton = new() { Text = "撤销", AutoSize = true, Enabled = false };
    private readonly Label _mailStatus = new() { Dock = DockStyle.Fill, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft };
    private readonly Button _mailNotices = new() { Text = "需处理邮件", Dock = DockStyle.Fill };
    private readonly Label _saveStatus = new() { AutoSize = true, Text = "已保存" };
    private readonly System.Windows.Forms.Timer _saveTimer = new() { Interval = 500 };
    private readonly Stack<string> _undo = new();
    private readonly InvoiceRepository _invoices;
    private readonly InvoiceWorkspace _invoiceWorkspace;
    private readonly BackgroundService _background;
    private bool _exitRequested;
    private bool _selfCheck;
    private bool _loadingProject;
    private bool _dirty;
    private readonly HashSet<Guid> _recognizing = [];
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TextBox _title = new() { Text = "报销单", Width = 310 };
    private readonly Button _export = new() { Text = "导出 Excel", AutoSize = true };
    private readonly FlowLayoutPanel _rows = new() { AutoScroll = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(0, 0, 4, 0) };
    private readonly Label _summary = new() { AutoSize = true };
    private readonly Label _blocker = new() { AutoSize = true, ForeColor = Color.DarkOrange };
    private Guid? _selected;
    private Point _dragStart;
    private bool _settingValues;

    public MainForm(string tessdataDirectory)
    {
        _tessdataDirectory = tessdataDirectory;
        Text = "报销单助手 1.34";
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        MinimumSize = new Size(1200, 700);
        Size = new Size(1440, 850);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 10);
        BackColor = Color.White;
        KeyPreview = true;
        _invoices = new InvoiceRepository(tessdataDirectory);
        _invoiceWorkspace = new InvoiceWorkspace(_invoices, () => _store.Projects, () => _project) { Dock = DockStyle.Fill, Visible = false };
        _background = new BackgroundService(_invoices, RestoreWindow, ShowInbox);
        _background.OpenSettings = OpenSettings;
        _invoiceWorkspace.SyncRequested += async (_, _) => await _background.SyncAsync();
        _invoices.AutomaticCleanupFailed += (_, message) => { RestoreWindow(); MessageBox.Show(this, message + "\n请在缓存设置中检查并重试。", "缓存自动清理已停止", MessageBoxButtons.OK, MessageBoxIcon.Warning); };
        _background.ExitRequested += (_, _) => { _exitRequested = true; Close(); };
        _background.StatusChanged += (_, _) => { _mailStatus.Text = _background.Status; _mailNotices.Text = $"需处理邮件（{_background.ManualMessages.Count}）"; _mailNotices.Enabled = _background.ManualMessages.Count > 0; };

        var shell = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 175));
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(shell);
        var sidebar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 8, Padding = new Padding(8), BackColor = Color.FromArgb(241, 244, 248) };
        sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        sidebar.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        for (var i = 2; i < 8; i++) sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, i is 3 or 4 ? 0 : 40));
        Button sideButton(string text, Action action) { var button = new Button { Text = text, Dock = DockStyle.Fill }; button.Click += (_, _) => action(); return button; }
        sidebar.Controls.Add(sideButton("我的项目", ShowOrders), 0, 0);
        sidebar.Controls.Add(_projects, 0, 1);
        sidebar.Controls.Add(sideButton("新建报销单", NewProject), 0, 2);
        var projectMenu = new ContextMenuStrip();
        projectMenu.Items.Add("打开项目", null, (_, _) => { if (_projects.SelectedItem is ProjectRecord item) LoadProject(item); });
        projectMenu.Items.Add("重命名", null, (_, _) => RenameProject());
        projectMenu.Items.Add("删除项目", null, (_, _) => DeleteProject());
        _projects.ContextMenuStrip = projectMenu;
        _projects.MouseDown += (_, e) => { if (e.Button == MouseButtons.Right) { var index = _projects.IndexFromPoint(e.Location); if (index >= 0) _projects.SelectedIndex = index; } };
        sidebar.Controls.Add(sideButton("发票箱", ShowInbox), 0, 5);
        sidebar.Controls.Add(sideButton("项目发票夹", ShowProjectInvoices), 0, 6);
        sidebar.Controls.Add(sideButton("设置", OpenSettings), 0, 7);
        shell.Controls.Add(sidebar, 0, 0);
        var workspace = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2 };
        workspace.RowStyles.Add(new RowStyle(SizeType.Absolute, 36)); workspace.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var mailBar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, Padding = new Padding(10, 0, 8, 0) };
        mailBar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); mailBar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105)); mailBar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 165));
        _mailStatus.Text = _background.Status;
        var sync = new Button { Text = "同步邮箱", Dock = DockStyle.Fill }; sync.Click += async (_, _) => await _background.SyncAsync();
        _mailNotices.Click += (_, _) => ShowMailNotices(); _mailNotices.Enabled = false;
        mailBar.Controls.Add(_mailStatus, 0, 0); mailBar.Controls.Add(sync, 1, 0); mailBar.Controls.Add(_mailNotices, 2, 0);
        workspace.Controls.Add(mailBar, 0, 0); workspace.Controls.Add(_host, 0, 1); shell.Controls.Add(workspace, 1, 0);
        _host.Controls.Add(_orderSplit);
        _host.Controls.Add(_invoiceWorkspace);
        var previewBox = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8), BackColor = Color.FromArgb(246, 248, 250) };
        _previewScroll.Controls.Add(_preview);
        previewBox.Controls.Add(_previewScroll);
        var zoomTools = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = true, Name = "previewZoom" };
        foreach (var (text, change) in new[] { ("−", -0.5), ("适合宽度", 0.0), ("+", 0.5) })
        {
            var button = new Button { Text = text, Width = change == 0 ? 85 : 30, Height = 28, Margin = new Padding(2) };
            button.Click += (_, _) => { _previewZoom = change == 0 ? 1 : Math.Clamp(_previewZoom + change, 0.5, 3); ResizePreview(); };
            zoomTools.Controls.Add(button);
        }
        var closePreview = new Button { Text = "收起", AutoSize = true };
        closePreview.Click += (_, _) => _orderSplit.Panel2Collapsed = true;
        zoomTools.Controls.Add(closePreview);
        previewBox.Controls.Add(zoomTools);
        previewBox.Controls.Add(_previewTitle);
        _previewScroll.Resize += (_, _) => ResizePreview();
        _orderSplit.Panel2.Controls.Add(previewBox);


        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(12) };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 84));
        _orderSplit.Panel1.Controls.Add(root);
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = true, AutoSize = true };
        toolbar.Controls.Add(new Label { Text = "报销单标题", AutoSize = true, Margin = new Padding(0, 8, 8, 0) });
        _title.Width = 240;
        toolbar.Controls.Add(_title);
        var import = new Button { Text = "导入截图", AutoSize = true };
        import.Click += (_, _) => ChooseImages();
        toolbar.Controls.Add(import);
        _export.Click += (_, _) => Export();
        toolbar.Controls.Add(_export);
        _undoButton.Click += (_, _) => Undo();
        toolbar.Controls.Add(_undoButton);
        root.Controls.Add(toolbar, 0, 0);
        var tools = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = true, AutoSize = true };
        tools.Controls.Add(_search);
        tools.Controls.Add(_onlyProblems);
        var next = new Button { Text = "查看待处理问题", AutoSize = true };
        next.Click += (_, _) => JumpToProblem(); tools.Controls.Add(next);
        var confirmAll = new Button { Text = "全部标记已人工核对", AutoSize = true };
        confirmAll.Click += (_, _) => { Remember(); foreach (var row in _expenses.Where(row => !row.Duplicate && !row.Pending)) row.Confirmed = true; foreach (var row in _expenses) RefreshRow(row); UpdateSummary(); };
        tools.Controls.Add(confirmAll);
        root.Controls.Add(tools, 0, 1);
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5, BackColor = Color.FromArgb(241, 244, 248), Padding = new Padding(8, 0, 18, 0) };
        SetColumns(header);
        var titles = new[] { "序号", "日期", "名称", "图片", "金额" };
        for (var i = 0; i < titles.Length; i++) header.Controls.Add(new Label { Text = titles[i], Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Font = new Font(Font, FontStyle.Bold) }, i, 0);
        root.Controls.Add(header, 0, 2);
        root.Controls.Add(_rows, 0, 3);
        var footer = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        footer.Controls.Add(_summary); footer.Controls.Add(_blocker); footer.Controls.Add(_saveStatus);
        root.Controls.Add(footer, 0, 4);
        _title.TextChanged += (_, _) => { if (!_loadingProject) { _project.Title = _title.Text; UpdateSummary(); } };
        _rows.Resize += (_, _) => { ResizeRows(); header.Padding = new Padding(8, 0, Math.Max(8, header.ClientSize.Width - RowWidth() + 8), 0); };
        _search.TextChanged += (_, _) => ApplyFilters();
        _onlyProblems.CheckedChanged += (_, _) => ApplyFilters();
        _projects.SelectedIndexChanged += (_, _) => { if (!_loadingProject && _projects.SelectedItem is ProjectRecord project) LoadProject(project); };
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); SaveCurrent(); };
        KeyDown += (_, e) => { if (e.Control && e.KeyCode == Keys.Z && !FocusedTextBox(this)) { Undo(); e.Handled = true; } if (e.Control && e.KeyCode == Keys.S) { SaveCurrent(); e.Handled = true; } };
        EnableDropTree(root);
        if (_store.Projects.Count == 0) _store.Create();
        RefreshProjects();
        LoadProject(_store.Projects.FirstOrDefault(project => project.Id == _store.LastSelectedId) ?? _store.Projects[0]);
        Shown += async (_, _) =>
        {
            _orderSplit.Panel1MinSize = 650;
            _orderSplit.Panel2MinSize = 240;
            _orderSplit.SplitterDistance = Math.Max(650, _orderSplit.Width - 285);
            if (_selfCheck) return;
            if (Environment.GetCommandLineArgs().Contains("--background")) Hide();
            if (_store.LoadErrors.Count > 0) MessageBox.Show(this, "部分项目无法读取，原文件已保留：\n" + string.Join("\n", _store.LoadErrors), "读取项目");
            try { await _invoices.RevalidateAsync(); }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "发票检查未完成"); }
            await _background.StartAsync();
        };
        FormClosing += (_, e) =>
        {
            if (!SaveCurrent()) { e.Cancel = true; return; }
            if (!_exitRequested && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            _lifetime.Cancel(); _background.Dispose(); _saveTimer.Dispose();
        };
    }

    private static void SetColumns(TableLayoutPanel panel)
    {
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 58));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 112));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 66));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
    }

    private void ChooseImages()
    {
        using var dialog = new OpenFileDialog { Title = "选择支付截图", Filter = "图片|*.png;*.jpg;*.jpeg;*.heic", Multiselect = true };
        if (dialog.ShowDialog(this) == DialogResult.OK) Import(dialog.FileNames);
    }

    private void Import(IEnumerable<string> paths)
    {
        var errors = new List<string>();
        foreach (var path in paths.Where(path => Extensions.Contains(Path.GetExtension(path))))
        {
            try
            {
                var bytes = File.ReadAllBytes(path);
                var fingerprint = Convert.ToHexString(SHA256.HashData(bytes));
                Remember();
                var duplicate = _expenses.Any(row => row.Fingerprint == fingerprint && !row.Duplicate);
                var row = new ExpenseRow
                {
                    ImagePath = _store.CopyScreenshot(_project, path),
                    OriginalFilename = Path.GetFileName(path),
                    Fingerprint = fingerprint,
                    Duplicate = duplicate,
                    Pending = !duplicate,
                    Warning = duplicate ? "重复截图，已排除在合计和导出之外。" : "正在识别…"
                };
                _expenses.Add(row);
                AddRow(row);
                if (!duplicate) _ = RecognizeAsync(row);
            }
            catch (Exception ex) { errors.Add($"{Path.GetFileName(path)}：{ex.Message}"); }
        }
        Renumber();
        UpdateSummary();
        if (errors.Count > 0) MessageBox.Show(this, string.Join(Environment.NewLine, errors), "导入未完成", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    private async Task RecognizeAsync(ExpenseRow row)
    {
        var owner = _store.Projects.FirstOrDefault(project => project.Expenses.Contains(row));
        if (owner == null || !_recognizing.Add(row.Id)) return;
        row.Pending = true;
        try
        {
            var suggestion = await Task.Run(() => Recognition.FromPng(ToPng(row.ImagePath), _tessdataDirectory), _lifetime.Token);
            if (!owner.Expenses.Contains(row)) return;
            if (!row.Edited.Contains("amount")) row.Amount = suggestion.Amount;
            if (!row.Edited.Contains("date")) row.Date = suggestion.Date ?? "";
            if (!row.Edited.Contains("category")) row.Category = suggestion.Category;
            if (!row.Edited.Contains("purpose")) row.Purpose = suggestion.Purpose;
            row.Warning = suggestion.Warning;
            row.RecognizedText = suggestion.RecognizedText;
            row.AmountCandidates = row.Amount == null ? suggestion.AmountCandidates : [];
            if (SemanticClassifier.NeedsAssistance(row))
            {
                if (_expenses.Contains(row)) RefreshRow(row);
                await SemanticClassifier.AssistAsync(row, _lifetime.Token);
            }
        }
        catch (OperationCanceledException) { row.Warning = "识别已中断，可重新识别或手动填写。"; }
        catch (Exception ex) { row.Warning = $"识别失败：{ex.Message}。请手动填写并确认。"; }
        finally
        {
            row.Pending = false; _recognizing.Remove(row.Id);
            if (owner.Expenses.Contains(row))
            {
                try { _store.Save(owner); } catch (Exception ex) { _saveStatus.Text = "保存失败：" + ex.Message; }
                if (_expenses.Contains(row)) { RefreshRow(row); UpdateSummary(); }
            }
            else if (owner.Expenses.FirstOrDefault(other => other.Id == row.Id && other.Pending) is { } restored) _ = RecognizeAsync(restored);
        }
    }

    private static byte[] ToPng(string path)
    {
        using var image = new MagickImage(path);
        image.Format = MagickFormat.Png;
        return image.ToByteArray();
    }

    private void AddRow(ExpenseRow row)
    {
        var panel = new TableLayoutPanel { Height = 260, Width = RowWidth(), ColumnCount = 5, RowCount = 1, Padding = new Padding(8, 7, 8, 7), Margin = new Padding(0), BackColor = Color.White, Tag = row.Id };
        SetColumns(panel);
        var numberBox = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        var number = new Label { AutoSize = true, Text = (_expenses.Count).ToString(CultureInfo.InvariantCulture), Margin = new Padding(2, 5, 0, 7) };
        var delete = new Button { Text = "删除", Width = 48, Height = 30, Font = new Font(Font.FontFamily, 8.5f), Margin = Padding.Empty };
        delete.Click += (_, _) => Delete(row);
        numberBox.Controls.Add(number);
        numberBox.Controls.Add(delete);
        panel.Controls.Add(numberBox, 0, 0);

        var date = new TextBox { Text = row.Date, Dock = DockStyle.Top, PlaceholderText = "年-月-日", Margin = new Padding(0, 5, 4, 0) };
        date.TextChanged += (_, _) => {
            if (_settingValues) return;
            Remember();
            var previous = row.Date;
            var input = date.Text;
            var digits = new string(input.Where(char.IsAsciiDigit).Take(8).ToArray());
            if (previous.EndsWith('-') && input == previous[..^1] && digits.Length > 0) digits = digits[..^1];
            var formatted = digits.Length < 4 ? digits : digits[..4] + "-" + (digits.Length > 4 ? digits[4..Math.Min(6, digits.Length)] : "") + (digits.Length >= 6 ? "-" + digits[6..] : "");
            row.Date = formatted; _settingValues = true; date.Text = formatted; date.SelectionStart = formatted.Length; _settingValues = false;
            MarkEdited(row, "date"); UpdateSummary();
        };
        panel.Controls.Add(date, 1, 0);

        var nameBox = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 4, ColumnCount = 1 };
        nameBox.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 116));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var purpose = new TextBox { Text = row.Purpose, Dock = DockStyle.Top, PlaceholderText = "填写用途" };
        purpose.TextChanged += (_, _) => { if (_settingValues) return; Remember(); row.Purpose = purpose.Text; MarkEdited(row, "purpose"); UpdateSummary(); };
        nameBox.Controls.Add(purpose, 0, 0);
        var categoryLine = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, FlowDirection = FlowDirection.TopDown };
        var category = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 98 };
        category.Items.AddRange(Categories);
        category.SelectedItem = Categories.Contains(row.Category) ? row.Category : "待分类";
        var recognizedText = new Button { Text = "识别文字", AutoSize = true, Enabled = false, Font = new Font(Font.FontFamily, 8.5f), Margin = new Padding(3, 0, 0, 0) };
        recognizedText.Click += (_, _) => ShowRecognizedText(row);
        categoryLine.Controls.Add(category);
        categoryLine.Controls.Add(recognizedText);
        nameBox.Controls.Add(categoryLine, 0, 1);
        var warning = new Label { Text = row.Warning ?? "", ForeColor = Color.DarkOrange, AutoEllipsis = true, Dock = DockStyle.Fill };
        nameBox.Controls.Add(warning, 0, 2);
        var confirmed = new CheckBox { Text = "已人工核对", AutoSize = true, Checked = row.Confirmed, Visible = !row.Duplicate && !row.Pending };
        confirmed.CheckedChanged += (_, _) => { if (_settingValues) return; Remember(); row.Confirmed = confirmed.Checked; UpdateSummary(); };
        nameBox.Controls.Add(confirmed, 0, 3);
        category.SelectedIndexChanged += (_, _) =>
        {
            if (_settingValues) return;
            Remember();
            var previous = row.Category;
            var selected = category.SelectedItem?.ToString() ?? "待分类";
            row.Category = selected;
            row.Confirmed = selected != "待分类";
            MarkEdited(row, "category");
            var oldDefault = previous == "待分类" ? "" : previous + "费用";
            if (string.IsNullOrWhiteSpace(row.Purpose) || row.Purpose == oldDefault)
            {
                row.Purpose = selected == "待分类" ? "" : selected + "费用";
                MarkEdited(row, "purpose");
                _settingValues = true;
                purpose.Text = row.Purpose;
                _settingValues = false;
            }
            _settingValues = true;
            confirmed.Checked = row.Confirmed;
            _settingValues = false;
            UpdateSummary();
        };
        panel.Controls.Add(nameBox, 2, 0);

        var image = new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Cursor = Cursors.Hand, Margin = new Padding(3, 0, 10, 5) };
        try { image.Image = LoadPreview(row.ImagePath); }
        catch { image.BackColor = Color.LightGray; }
        image.Click += (_, _) => ShowPreview(row);
        panel.Controls.Add(image, 3, 0);

        var amountBox = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3 };
        amountBox.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        amountBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        amountBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
        amountBox.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var amount = new TextBox { Text = row.Amount?.ToString("0.00", CultureInfo.InvariantCulture) ?? "", Dock = DockStyle.Top, PlaceholderText = "金额", Margin = new Padding(0, 5, 0, 0) };
        amount.TextChanged += (_, _) =>
        {
            if (_settingValues) return;
            Remember();
            MarkEdited(row, "amount");
            row.Amount = Regex.IsMatch(amount.Text.Trim(), @"^\d+(?:\.\d{1,2})?$") && decimal.TryParse(amount.Text, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var value) ? value : null;
            UpdateSummary();
        };
        amountBox.Controls.Add(amount, 0, 0);
        var candidateHint = new Label { Text = "点击选择金额", AutoSize = true, ForeColor = Color.DimGray, Visible = false };
        amountBox.Controls.Add(candidateHint, 0, 1);
        var candidates = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Visible = false };
        candidates.Resize += (_, _) => { foreach (Control button in candidates.Controls) button.Width = CandidateWidth(candidates); };
        amountBox.Controls.Add(candidates, 0, 2);
        panel.Controls.Add(amountBox, 4, 0);

        panel.MouseDown += (_, e) => { SelectRow(row.Id); _dragStart = e.Location; };
        panel.MouseMove += (_, e) => StartRowDrag(panel, row, e.Location, e.Button);
        number.MouseDown += (_, e) => { SelectRow(row.Id); _dragStart = e.Location; };
        number.MouseMove += (_, e) => StartRowDrag(number, row, e.Location, e.Button);
        foreach (var control in new Control[] { numberBox, number, date, nameBox, purpose, categoryLine, category, recognizedText, warning, confirmed, image, amountBox, amount, candidateHint, candidates, delete })
        {
            control.MouseDown += (_, _) => SelectRow(row.Id);
            EnableDrop(control);
        }
        foreach (var handle in new Control[] { numberBox, warning, image })
        {
            handle.MouseDown += (_, e) => _dragStart = e.Location;
            handle.MouseMove += (_, e) => StartRowDrag(handle, row, e.Location, e.Button);
        }
        EnableDrop(panel);
        _rows.Controls.Add(panel);
        _controls[row.Id] = new RowControls(panel, number, date, purpose, category, warning, confirmed, amount, image, recognizedText, candidateHint, candidates);
        panel.Click += (_, _) => SelectRow(row.Id);
    }

    private static Bitmap LoadPreview(string path, int maximumWidth = 240)
    {
        using var stream = new MemoryStream(ToPng(path));
        using var source = new Bitmap(stream);
        var scale = Math.Min(1d, Math.Min((double)maximumWidth / source.Width, 4096d / source.Height));
        return new Bitmap(source, new Size(Math.Max(1, (int)(source.Width * scale)), Math.Max(1, (int)(source.Height * scale))));
    }

    private void ShowPreview(ExpenseRow row) => SelectRow(row.Id);

    private void ShowRecognizedText(ExpenseRow row)
    {
        using var dialog = new Form { Text = "识别文字", Size = new Size(650, 510), StartPosition = FormStartPosition.CenterParent };
        dialog.Controls.Add(new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Text = row.RecognizedText, Font = Font });
        dialog.ShowDialog(this);
    }

    private void RefreshRow(ExpenseRow row)
    {
        if (!_controls.TryGetValue(row.Id, out var ui)) return;
        _settingValues = true;
        ui.Date.Text = row.Date;
        ui.Purpose.Text = row.Purpose;
        ui.Category.SelectedItem = row.Category;
        ui.Amount.Text = row.Amount?.ToString("0.00", CultureInfo.InvariantCulture) ?? "";
        ui.Warning.Text = row.Pending ? "正在识别…" : row.Status + (row.Issues.Count > 0 ? " · " + string.Join("；", row.Issues) : "") + (string.IsNullOrEmpty(row.AiNote) ? "" : " · " + row.AiNote);
        ui.Confirmed.Visible = !row.Duplicate && !row.Pending;
        ui.Confirmed.Checked = row.Confirmed;
        ui.RecognizedText.Enabled = !string.IsNullOrWhiteSpace(row.RecognizedText);
        ui.Panel.Height = row.AmountCandidates.Count > 0 ? 280 : 260;
        ui.CandidateHint.Visible = row.AmountCandidates.Count > 0 && !row.Duplicate;
        ui.Candidates.Visible = ui.CandidateHint.Visible;
        {
            foreach (Control old in ui.Candidates.Controls.Cast<Control>().ToArray()) old.Dispose();
            ui.Candidates.Controls.Clear();
            foreach (var candidate in row.AmountCandidates)
            {
                var button = new Button { Width = CandidateWidth(ui.Candidates), Height = 26, Margin = new Padding(0, 0, 0, 2) };
                var tip = new ToolTip();
                tip.SetToolTip(button, candidate.Source);
                button.Disposed += (_, _) => tip.Dispose();
                button.Click += (_, _) =>
                {
                    if (!_expenses.Contains(row) || row.Duplicate) return;
                    Remember();
                    row.Amount = candidate.Amount;
                    row.Confirmed = true;
                    row.Edited.Add("amount");
                    RefreshRow(row);
                    UpdateSummary();
                };
                button.MouseDown += (_, _) => SelectRow(row.Id);
                EnableDrop(button);
                ui.Candidates.Controls.Add(button);
            }
        }
        for (var i = 0; i < row.AmountCandidates.Count; i++)
            ui.Candidates.Controls[i].Text = $"{(row.Amount == row.AmountCandidates[i].Amount ? "✓ " : "")}¥{row.AmountCandidates[i].Amount:0.##}";
        _settingValues = false;
    }

    private void MarkEdited(ExpenseRow row, string field)
    {
        row.Edited.Add(field); row.AiRecognized = false;
    }

    private void SelectRow(Guid id)
    {
        _selected = id;
        var expense = _expenses.FirstOrDefault(row => row.Id == id);
        _preview.Image?.Dispose(); _preview.Image = null;
        if (expense != null) { try { _orderSplit.Panel2Collapsed = false; _preview.Image = LoadPreview(expense.ImagePath, 2200); _previewZoom = 1; ResizePreview(); _previewTitle.Text = (string.IsNullOrEmpty(expense.OriginalFilename) ? Path.GetFileName(expense.ImagePath) : expense.OriginalFilename); } catch { _previewTitle.Text = "截图无法读取"; } }
        foreach (var (rowId, ui) in _controls)
        {
            var color = rowId == id ? Color.FromArgb(219, 235, 255) : Color.White;
            SetContainerColor(ui.Panel, color);
        }
    }

    private static void SetContainerColor(Control control, Color color)
    {
        if (control is Panel or TableLayoutPanel or FlowLayoutPanel) control.BackColor = color;
        foreach (Control child in control.Controls) SetContainerColor(child, color);
    }

    private void StartRowDrag(Control source, ExpenseRow row, Point location, MouseButtons buttons)
    {
        if (buttons != MouseButtons.Left || _selected != row.Id || Math.Abs(location.X - _dragStart.X) + Math.Abs(location.Y - _dragStart.Y) < 8) return;
        var data = new DataObject();
        data.SetData("ReimburseExpenseRow", row.Id.ToString());
        source.DoDragDrop(data, DragDropEffects.Move);
    }

    private void EnableDrop(Control control)
    {
        control.AllowDrop = true;
        control.DragEnter += (_, e) =>
        {
            if (e.Data?.GetDataPresent(DataFormats.FileDrop) == true) e.Effect = DragDropEffects.Copy;
            else if (e.Data?.GetDataPresent("ReimburseExpenseRow") == true) e.Effect = DragDropEffects.Move;
        };
        control.DragDrop += (_, e) =>
        {
            if (e.Data?.GetData(DataFormats.FileDrop) is string[] files) { Import(files); return; }
            if (e.Data?.GetData("ReimburseExpenseRow") is not string source || !Guid.TryParse(source, out var sourceId)) return;
            var targetId = (control.Tag as Guid?) ?? FindRowId(control);
            if (targetId is Guid id) MoveRow(sourceId, id);
        };
    }

    private static Guid? FindRowId(Control control)
    {
        for (Control? current = control; current != null; current = current.Parent)
            if (current.Tag is Guid id) return id;
        return null;
    }

    private void MoveRow(Guid sourceId, Guid targetId)
    {
        if (sourceId == targetId) return;
        var source = _expenses.FindIndex(row => row.Id == sourceId);
        var target = _expenses.FindIndex(row => row.Id == targetId);
        if (source < 0 || target < 0) return;
        Remember();
        var row = _expenses[source];
        _expenses.RemoveAt(source);
        _expenses.Insert(target, row);
        _rows.Controls.SetChildIndex(_controls[sourceId].Panel, target);
        Renumber();
        SelectRow(sourceId);
        UpdateSummary();
    }

    private void Delete(ExpenseRow row)
    {
        Remember();
        var wasDuplicate = row.Duplicate;
        _expenses.Remove(row);

        if (_controls.Remove(row.Id, out var ui))
        {
            _rows.Controls.Remove(ui.Panel);
            ui.Image.Image?.Dispose();
            ui.Panel.Dispose();
        }
        if (_selected == row.Id) { _selected = null; _preview.Image?.Dispose(); _preview.Image = null; _previewTitle.Text = "点击一笔订单查看截图"; }
        if (!wasDuplicate)
        {
            var promoted = _expenses.FirstOrDefault(candidate => candidate.Fingerprint == row.Fingerprint && candidate.Duplicate);
            if (promoted != null)
            {
                promoted.Duplicate = false;
                promoted.Pending = true;
                promoted.Warning = "正在识别…";
                RefreshRow(promoted);
                _ = RecognizeAsync(promoted);
            }
        }
        Renumber();
        UpdateSummary();
    }

    private void Renumber()
    {
        for (var i = 0; i < _expenses.Count; i++) _controls[_expenses[i].Id].Number.Text = (i + 1).ToString(CultureInfo.InvariantCulture);
    }

    private static int CandidateWidth(FlowLayoutPanel panel) => Math.Max(1, panel.ClientSize.Width - panel.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth - 2);
    private int RowWidth() => Math.Max(1, _rows.ClientSize.Width - _rows.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth - 2);
    private void ResizeRows() { foreach (var ui in _controls.Values) ui.Panel.Width = RowWidth(); }

    private string? Blocker()
    {
        if (string.IsNullOrWhiteSpace(_title.Text)) return "请填写报销单标题。";
        if (!_expenses.Any(row => !row.Duplicate)) return "请先导入截图。";
        for (var i = 0; i < _expenses.Count; i++)
            if (_expenses[i].Issues.Count > 0) return $"第{i + 1}笔：{string.Join("；", _expenses[i].Issues)}";
        return null;
    }

    private void UpdateSummary()
    {
        var unique = _expenses.Where(row => !row.Duplicate).ToList();
        var total = unique.Where(row => row.Amount > 0).Sum(row => row.Amount ?? 0);
        var pending = unique.Count(row => row.Issues.Count > 0);
        _summary.Text = $"已导入 {_expenses.Count} 张 · 有效 {unique.Count} 笔 · 待处理 {pending} 笔 · 已填合计 ¥{total:N2}";
        foreach (var row in _expenses)
            if (_controls.TryGetValue(row.Id, out var ui)) ui.Warning.Text = row.Pending ? "正在识别…" : row.Status + (row.Issues.Count > 0 ? " · " + string.Join("；", row.Issues) : "") + (string.IsNullOrEmpty(row.AiNote) ? "" : " · " + row.AiNote);
        _blocker.Text = Blocker() ?? "可导出";
        _export.Enabled = Blocker() == null;
        _undoButton.Enabled = _undo.Count > 0 && !_expenses.Any(row => row.Pending);
        ApplyFilters();
        if (!_loadingProject) { _dirty = true; _saveStatus.Text = "等待保存…"; _saveTimer.Stop(); _saveTimer.Start(); }
    }

    private void Export()
    {
        var blocker = Blocker();
        if (blocker != null) { MessageBox.Show(this, blocker, "请先核对", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        using var dialog = new SaveFileDialog { Filter = "Excel 工作簿|*.xlsx", FileName = _title.Text.Trim() + ".xlsx", DefaultExt = "xlsx" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try { WorkbookExporter.Export(dialog.FileName, _title.Text, _expenses.Where(row => !row.Duplicate).ToList()); }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "导出失败", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    internal void SelfCheck()
    {
        _selfCheck = true;
        Show(); Application.DoEvents();
        using (var screenshot = new Bitmap(Width, Height)) { DrawToBitmap(screenshot, new Rectangle(Point.Empty, Size)); screenshot.Save("build/windows-smoke.png", ImageFormat.Png); }
        if (_orderSplit.Width < 650 || !_title.Visible || !_export.Visible) throw new InvalidOperationException($"主窗口未正确显示（window={Size}, workspace={_orderSplit.Size}, title={_title.Visible}, export={_export.Visible}）");
        var imagePath = Path.Combine(AppPaths.Root, "sample.png");
        using (var image = new Bitmap(700, 220))
        {
            using var graphics = Graphics.FromImage(image); graphics.Clear(Color.White);
            using var font = new Font("Arial", 28);
            graphics.DrawString("Payment 39.00", font, Brushes.Black, 30, 70);
            image.Save(imagePath, ImageFormat.Png);
        }
        _ = Recognition.FromPng(File.ReadAllBytes(imagePath), _tessdataDirectory);
        var row = new ExpenseRow { ImagePath = imagePath, OriginalFilename = "sample.png", Amount = 39m, Purpose = "交通费用", Category = "交通", Date = "2026-09-24" };
        _expenses.Add(row); AddRow(row); RefreshRow(row); UpdateSummary(); SaveCurrent();
        if (!_export.Enabled || _project.Expenses.Count != 1) throw new InvalidOperationException("订单保存或导出校验失败");
        row.AmountCandidates = [new(49m, "新候选")]; row.Amount = null; RefreshRow(row);
        row.Edited.Add("amount"); row.Amount = 49m; RefreshRow(row);
        if (_controls[row.Id].Amount.Text != "49.00") throw new InvalidOperationException("人工金额未正确显示");
        var export = Path.Combine(AppPaths.Root, "self-check.xlsx");
        WorkbookExporter.Export(export, _project.Title, _expenses);
        if (!File.Exists(export)) throw new InvalidOperationException("Excel 未生成");
        var storedPath = Path.Combine(ProjectStore.DirectoryFor(_project), "project.json");
        var savedBytes = File.ReadAllBytes(storedPath); var savedTime = File.GetLastWriteTimeUtc(storedPath);
        var stableProject = ProjectStore.Restore(File.ReadAllText(storedPath));
        _store.Save(stableProject); _store.Select(stableProject);
        if (!savedBytes.SequenceEqual(File.ReadAllBytes(storedPath)) || savedTime != File.GetLastWriteTimeUtc(storedPath)) throw new InvalidOperationException("无变化保存不应修改项目资料");
        var mailDetail = MailDetail.FromText("<script>location=\"https://bad.test\"</script><p>正文</p><img src=\"https://remote.test/image\"><a href=\"https://example.com/invoice\">下载</a>", true);
        if (mailDetail.Body.Contains("<") || mailDetail.Body.Contains("location=") || !mailDetail.Body.Contains("正文") || mailDetail.Links.Any(link => link.Scheme is not ("http" or "https"))) throw new InvalidOperationException("邮件纯文本安全转换失败");
        if (GitHubUpdatesPanel.ParseVersion("v1.34.0") <= GitHubUpdatesPanel.ParseVersion("v1.9.0")) throw new InvalidOperationException("更新版本数值比较失败");
        ShowPreview(row); if (_orderSplit.Panel2Collapsed || _preview.Image == null) throw new InvalidOperationException("订单未在右侧栏预览");
        var reloaded = new ProjectStore();
        if (reloaded.Projects.Single().Expenses.Single().Amount != 39m) throw new InvalidOperationException("自动保存读取不一致");
        Size = MinimumSize; Application.DoEvents();
        using (var screenshot = new Bitmap(Width, Height)) { DrawToBitmap(screenshot, new Rectangle(Point.Empty, Size)); screenshot.Save("build/windows-orders-smoke.png", ImageFormat.Png); }
        var compactRow = _controls[row.Id];
        var purposeRequired = TextRenderer.MeasureText("道具采购费用", compactRow.Purpose.Font).Width + 12;
        if (compactRow.Purpose.ClientSize.Width < purposeRequired || compactRow.Purpose.Right > compactRow.Purpose.Parent!.ClientSize.Width)
            throw new InvalidOperationException($"用途输入空间不足：width={compactRow.Purpose.ClientSize.Width}, required={purposeRequired}, right={compactRow.Purpose.Right}, parent={compactRow.Purpose.Parent!.ClientSize}, row={compactRow.Panel.Size}");
        if (compactRow.Confirmed.PreferredSize.Width > compactRow.Confirmed.Width || compactRow.Confirmed.Right > compactRow.Confirmed.Parent!.ClientSize.Width)
            throw new InvalidOperationException($"人工核对未完整显示：bounds={compactRow.Confirmed.Bounds}, preferred={compactRow.Confirmed.PreferredSize}, parent={compactRow.Confirmed.Parent!.ClientSize}");
        if (compactRow.Candidates.Controls.Cast<Control>().Any(control => control.Right > compactRow.Candidates.ClientSize.Width)) throw new InvalidOperationException("金额候选按钮超出可见区域");
        var categoryActions = _controls[row.Id].Category.Parent!;
        if (categoryActions.Controls.Cast<Control>().Any(control => control.Right > categoryActions.ClientSize.Width || control.Bottom > categoryActions.ClientSize.Height)) throw new InvalidOperationException("订单分类或 AI 按钮被遮挡");
        using (var screenshot = new Bitmap(Width, Height)) { DrawToBitmap(screenshot, new Rectangle(Point.Empty, Size)); screenshot.Save("build/windows-orders-smoke.png", ImageFormat.Png); }
        if (_rows.HorizontalScroll.Visible) throw new InvalidOperationException($"订单栏目超出可见宽度：window={Size}, split={_orderSplit.Size}, left={_orderSplit.Panel1.ClientSize}, rows={_rows.ClientSize}, display={_rows.DisplayRectangle}, row={_controls[row.Id].Panel.Size}, requested={RowWidth()}, padding={_rows.Padding}, scroll={_rows.HorizontalScroll.Maximum}");
        if (_controls[row.Id].Panel.Height < 200) throw new InvalidOperationException("订单操作区域高度不足");
        var zoom = _orderSplit.Panel2.Controls.Find("previewZoom", true).Single();
        if (zoom.Controls.Cast<Control>().Any(control => control.Right > zoom.ClientSize.Width || control.Bottom > zoom.ClientSize.Height)) throw new InvalidOperationException("截图缩放按钮被遮挡");
        using (var screenshot = new Bitmap(Width, Height)) { DrawToBitmap(screenshot, new Rectangle(Point.Empty, Size)); screenshot.Save("build/windows-orders-smoke.png", ImageFormat.Png); }
        var settings = AppSettings.Current.Copy();
        settings.AiModel = "fixture-ds-model"; settings.ApiKey = "fixture-deepseek-secret"; settings.CaptureAiProfile();
        settings.SelectAiProvider("阿里百炼"); settings.AiModel = "fixture-aliyun-model"; settings.ApiKey = "fixture-aliyun-secret";
        AppSettings.Replace(settings);
        var plain = File.ReadAllText(Path.Combine(AppPaths.Root, "settings.json"));
        if (plain.Contains("fixture-deepseek-secret") || plain.Contains("fixture-aliyun-secret")) throw new InvalidOperationException("设置中出现明文密钥");
        var loaded = (AppSettings)typeof(AppSettings).GetMethod("Load", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic)!.Invoke(null, null)!;
        loaded.SelectAiProvider("DeepSeek");
        if (loaded.ApiKey != "fixture-deepseek-secret" || loaded.AiModel != "fixture-ds-model") throw new InvalidOperationException("DeepSeek 独立配置读取失败");
        loaded.SelectAiProvider("阿里百炼");
        if (loaded.ApiKey != "fixture-aliyun-secret" || loaded.AiModel != "fixture-aliyun-model") throw new InvalidOperationException("阿里独立配置读取失败");
        _exitRequested = true; Close();
    }

    private static bool FocusedTextBox(Control parent) => parent is TextBoxBase && parent.Focused || parent.Controls.Cast<Control>().Any(FocusedTextBox);
    private void ResizePreview()
    {
        if (_preview.Image == null) return;
        var width = Math.Max(50, (int)((_previewScroll.ClientSize.Width - 22) * _previewZoom));
        _preview.Size = new Size(width, Math.Max(1, (int)((double)_preview.Image.Height / _preview.Image.Width * width)));
    }
    private async Task AssistRowAsync(ExpenseRow row, bool explicitlyRequested = false)
    {
        var owner = _store.Projects.FirstOrDefault(project => project.Expenses.Contains(row));
        if (owner == null || !_recognizing.Add(row.Id)) return;
        row.Pending = true;
        if (_expenses.Contains(row)) { RefreshRow(row); UpdateSummary(); }
        try { await SemanticClassifier.AssistAsync(row, _lifetime.Token, explicitlyRequested); }
        catch (OperationCanceledException) { row.AiNote = "AI 识别已停止"; }
        catch (Exception ex) { row.AiNote = ex.Message; }
        finally
        {
            row.Pending = false; _recognizing.Remove(row.Id);
            if (owner.Expenses.Contains(row))
            {
                try { _store.Save(owner); } catch (Exception ex) { _saveStatus.Text = "保存失败：" + ex.Message; }
                if (_expenses.Contains(row)) { RefreshRow(row); UpdateSummary(); }
            }
            else if (owner.Expenses.FirstOrDefault(other => other.Id == row.Id && other.Pending) is { } restored) _ = RecognizeAsync(restored);
        }
    }

    private void EnableDropTree(Control parent)
    {
        EnableDrop(parent);
        foreach (Control child in parent.Controls) EnableDropTree(child);
    }
    private void Remember()
    {
        if (_loadingProject || _project == null) return;
        if (_undo.Count >= 30) { var remaining = _undo.Reverse().Skip(1).ToArray(); _undo.Clear(); foreach (var snapshot in remaining) _undo.Push(snapshot); }
        _undo.Push(ProjectStore.Snapshot(_project));
        _undoButton.Enabled = true;
    }
    private void Undo()
    {
        if (_undo.Count == 0 || _expenses.Any(row => row.Pending)) return;
        var restored = ProjectStore.Restore(_undo.Pop());
        _project.Title = restored.Title;
        _project.Expenses = restored.Expenses;
        LoadProject(_project, clearUndo: false);
        _undoButton.Enabled = _undo.Count > 0;
        _dirty = true; SaveCurrent();
    }
    private bool SaveCurrent()
    {
        if (_project == null || !_dirty) return true;
        try { _store.Save(_project); _dirty = false; _saveStatus.Text = "已保存"; return true; }
        catch (Exception ex) { _saveStatus.Text = "保存失败：" + ex.Message; MessageBox.Show(this, "保存失败，原资料保留，请检查磁盘空间和权限：\n" + ex.Message, "无法保存", MessageBoxButtons.OK, MessageBoxIcon.Error); return false; }
    }
    private void RefreshProjects()
    {
        _loadingProject = true;
        _projects.Items.Clear();
        foreach (var project in _store.Projects) _projects.Items.Add(project);
        if (_project != null) _projects.SelectedItem = _project;
        _loadingProject = false;
    }
    private void LoadProject(ProjectRecord project, bool clearUndo = true)
    {
        if (!SaveCurrent()) { RefreshProjects(); return; }
        _loadingProject = true;
        foreach (var ui in _controls.Values) { ui.Image.Image?.Dispose(); ui.Panel.Dispose(); }
        _rows.Controls.Clear(); _controls.Clear();
        _project = project; _expenses = project.Expenses; _title.Text = project.Title;
        _selected = null; _preview.Image?.Dispose(); _preview.Image = null; _previewTitle.Text = "点击一笔订单查看截图";
        if (clearUndo) _undo.Clear();
        _undoButton.Enabled = _undo.Count > 0;
        foreach (var row in _expenses) { AddRow(row); RefreshRow(row); }
        Renumber(); UpdateSummary();
        _loadingProject = false;
        RefreshProjects(); ShowOrders();
        try { _store.Select(project); } catch (Exception ex) { _saveStatus.Text = "无法记录当前项目：" + ex.Message; }
        if (_expenses.Count > 0) SelectRow(_expenses[0].Id);
        foreach (var row in _expenses.Where(row => row.Pending && !_recognizing.Contains(row.Id)).ToArray()) _ = RecognizeAsync(row);
    }
    private void NewProject()
    {
        if (!SaveCurrent()) return;
        try { LoadProject(_store.Create()); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "无法创建项目"); }
    }
    private void RenameProject()
    {
        using var dialog = new Form { Text = "重命名报销单", Width = 420, Height = 160, StartPosition = FormStartPosition.CenterParent };
        var input = new TextBox { Text = _project.Title, Dock = DockStyle.Top };
        var ok = new Button { Text = "保存", Dock = DockStyle.Bottom, DialogResult = DialogResult.OK };
        dialog.Controls.Add(input); dialog.Controls.Add(ok); dialog.AcceptButton = ok;
        if (dialog.ShowDialog(this) == DialogResult.OK && !string.IsNullOrWhiteSpace(input.Text)) { Remember(); _project.Title = input.Text.Trim(); _title.Text = _project.Title; _dirty = true; SaveCurrent(); RefreshProjects(); }
    }
    private async void DeleteProject()
    {
        if (_expenses.Any(row => row.Pending)) { MessageBox.Show(this, "请等待识别完成后再删除项目。", "正在处理"); return; }
        if (MessageBox.Show(this, "将此项目资料移入回收站？发票箱原件、邮箱及已导出文件保留。", "删除项目", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        _host.Enabled = false;
        try
        {
            _saveTimer.Stop(); var deletedId = _project.Id;
            _store.Delete(_project); _dirty = false;
            try { await _invoices.DetachProjectAsync(deletedId); }
            catch (Exception ex) { MessageBox.Show(this, "项目已移入回收站，但发票归属释放未完成：" + ex.Message, "请检查发票归属"); }
            if (_store.Projects.Count == 0) _store.Create();
            LoadProject(_store.Projects[0]);
        }
        catch (Exception ex) { MessageBox.Show(this, "删除已停止：" + ex.Message, "无法移入回收站"); }
        finally { _host.Enabled = true; }
    }
    private void RestoreWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    private void ShowOrders() { _invoiceWorkspace.Visible = false; _orderSplit.Visible = true; _orderSplit.BringToFront(); }
    private void ShowInbox() { RestoreWindow(); _orderSplit.Visible = false; _invoiceWorkspace.Visible = true; _invoiceWorkspace.ShowInbox(); _invoiceWorkspace.BringToFront(); }
    private void ShowProjectInvoices() { if (!SaveCurrent()) return; _orderSplit.Visible = false; _invoiceWorkspace.Visible = true; _invoiceWorkspace.ShowProject(_project); _invoiceWorkspace.BringToFront(); }
    private async void OpenSettings()
    {
        using var settings = new SettingsForm(_tessdataDirectory, _invoices);
        if (settings.ShowDialog(this) == DialogResult.OK)
        {
            await _background.SettingsChangedAsync();
            await _invoices.RevalidateAsync();
            if (AppSettings.Current.AiEnabled)
                foreach (var row in _store.Projects.SelectMany(project => project.Expenses).Where(row => !row.Pending && SemanticClassifier.NeedsAssistance(row)).ToArray()) await AssistRowAsync(row);
        }
    }
    private void ShowMailNotices()
    {
        using var form = new Form { Text = "需在 QQ 邮箱处理的邮件", Size = new Size(720, 420), StartPosition = FormStartPosition.CenterParent };
        var list = new ListBox { Dock = DockStyle.Fill, IntegralHeight = false };
        var notices = _background.ManualMessages.ToList();
        foreach (var notice in notices) list.Items.Add($"{notice.ReceivedAt:yyyy-MM-dd} · {notice.Sender} · {notice.Subject}");
        var tools = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44 };
        var open = new Button { Text = "打开 QQ 邮箱", AutoSize = true };
        open.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://mail.qq.com") { UseShellExecute = true });
        var dismiss = new Button { Text = "忽略选中提醒", AutoSize = true };
        dismiss.Click += (_, _) => { if (list.SelectedIndex < 0) return; var index = list.SelectedIndex; _background.DismissNotice(notices[index].Id); notices.RemoveAt(index); list.Items.RemoveAt(index); };
        var details = new Button { Text = "查看邮件", AutoSize = true };
        details.Click += async (_, _) => { if (list.SelectedIndex < 0) return; var notice = notices[list.SelectedIndex]; form.Close(); ShowInbox(); await _invoiceWorkspace.ShowMailAsync(notice); };
        tools.Controls.Add(details); tools.Controls.Add(open); tools.Controls.Add(dismiss);
        form.Controls.Add(list); form.Controls.Add(tools); form.ShowDialog(this);
    }

    private void ApplyFilters()
    {
        var query = _search.Text.Trim();
        foreach (var row in _expenses)
            if (_controls.TryGetValue(row.Id, out var ui)) ui.Panel.Visible = (!_onlyProblems.Checked || row.Issues.Count > 0) && (query.Length == 0 || (row.Amount?.ToString("0.00", CultureInfo.InvariantCulture).Contains(query) ?? false));
        if (_onlyProblems.Checked && _selected is Guid id && _controls.TryGetValue(id, out var current) && !current.Panel.Visible)
        {
            var next = _expenses.FirstOrDefault(row => _controls[row.Id].Panel.Visible);
            if (next != null) { SelectRow(next.Id); _rows.ScrollControlIntoView(_controls[next.Id].Panel); }
        }
    }
    private void JumpToProblem()
    {
        var first = _expenses.FirstOrDefault(row => row.Issues.Count > 0);
        if (first == null) { MessageBox.Show(this, "当前订单均可导出。", "待处理问题"); return; }
        _search.Clear(); _onlyProblems.Checked = true; SelectRow(first.Id); _rows.ScrollControlIntoView(_controls[first.Id].Panel);
    }

    private sealed record RowControls(TableLayoutPanel Panel, Label Number, TextBox Date, TextBox Purpose, ComboBox Category, Label Warning, CheckBox Confirmed, TextBox Amount, PictureBox Image, Button RecognizedText, Label CandidateHint, FlowLayoutPanel Candidates);
}
