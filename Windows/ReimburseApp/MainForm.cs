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
    private readonly PictureBox _preview = new() { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Cursor = Cursors.Hand };
    private readonly Label _previewTitle = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(8), Text = "点击一笔订单查看截图" };
    private readonly TextBox _search = new() { Width = 145, PlaceholderText = "搜索已填写金额" };
    private readonly CheckBox _onlyProblems = new() { Text = "只看待处理", AutoSize = true };
    private readonly Button _undoButton = new() { Text = "撤销", AutoSize = true, Enabled = false };
    private readonly Label _saveStatus = new() { AutoSize = true, Text = "已保存" };
    private readonly System.Windows.Forms.Timer _saveTimer = new() { Interval = 500 };
    private readonly Stack<string> _undo = new();
    private readonly InvoiceRepository _invoices;
    private readonly InvoiceWorkspace _invoiceWorkspace;
    private readonly BackgroundService _background;
    private bool _exitRequested;
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
        Text = "报销单助手 1.27";
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
        _background.StatusChanged += (_, _) => _saveStatus.Text = _dirty ? "等待保存…" : "已保存 · " + _background.Status;

        var shell = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 175));
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(shell);
        var sidebar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 8, Padding = new Padding(8), BackColor = Color.FromArgb(241, 244, 248) };
        sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        sidebar.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        for (var i = 2; i < 8; i++) sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        Button sideButton(string text, Action action) { var button = new Button { Text = text, Dock = DockStyle.Fill }; button.Click += (_, _) => action(); return button; }
        sidebar.Controls.Add(sideButton("我的项目", ShowOrders), 0, 0);
        sidebar.Controls.Add(_projects, 0, 1);
        sidebar.Controls.Add(sideButton("新建报销单", NewProject), 0, 2);
        sidebar.Controls.Add(sideButton("重命名项目", RenameProject), 0, 3);
        sidebar.Controls.Add(sideButton("删除项目", DeleteProject), 0, 4);
        sidebar.Controls.Add(sideButton("发票箱", ShowInbox), 0, 5);
        sidebar.Controls.Add(sideButton("项目发票夹", ShowProjectInvoices), 0, 6);
        sidebar.Controls.Add(sideButton("设置", OpenSettings), 0, 7);
        shell.Controls.Add(sidebar, 0, 0);
        shell.Controls.Add(_host, 1, 0);
        _host.Controls.Add(_orderSplit);
        _host.Controls.Add(_invoiceWorkspace);
        var previewBox = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8), BackColor = Color.FromArgb(246, 248, 250) };
        previewBox.Controls.Add(_preview);
        previewBox.Controls.Add(_previewTitle);
        _orderSplit.Panel2.Controls.Add(previewBox);
        _preview.Click += (_, _) => { if (_expenses.FirstOrDefault(row => row.Id == _selected) is { } row) ShowPreview(row); };

        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(12) };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 60));
        _orderSplit.Panel1.Controls.Add(root);
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
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
        var tools = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
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
        _rows.Resize += (_, _) => ResizeRows();
        _search.TextChanged += (_, _) => ApplyFilters();
        _onlyProblems.CheckedChanged += (_, _) => ApplyFilters();
        _projects.SelectedIndexChanged += (_, _) => { if (!_loadingProject && _projects.SelectedItem is ProjectRecord project) LoadProject(project); };
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); SaveCurrent(); };
        KeyDown += (_, e) => { if (e.Control && e.KeyCode == Keys.Z && ActiveControl is not TextBoxBase) { Undo(); e.Handled = true; } if (e.Control && e.KeyCode == Keys.S) { SaveCurrent(); e.Handled = true; } };
        EnableDropTree(root);
        if (_store.Projects.Count == 0) _store.Create();
        RefreshProjects();
        LoadProject(_store.Projects[0]);
        Shown += async (_, _) =>
        {
            _orderSplit.SplitterDistance = Math.Max(650, _orderSplit.Width - 285);
            if (Environment.GetCommandLineArgs().Contains("--background")) Hide();
            if (_store.LoadErrors.Count > 0) MessageBox.Show(this, "部分项目无法读取，原文件已保留：\n" + string.Join("\n", _store.LoadErrors), "读取项目");
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
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 72));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 125));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 145));
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
        var panel = new TableLayoutPanel { Height = 162, Width = RowWidth(), ColumnCount = 5, RowCount = 1, Padding = new Padding(8, 7, 8, 7), Margin = new Padding(0), BackColor = Color.White, Tag = row.Id };
        SetColumns(panel);
        var numberBox = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        var number = new Label { AutoSize = true, Text = (_expenses.Count).ToString(CultureInfo.InvariantCulture), Margin = new Padding(2, 5, 0, 7) };
        var delete = new Button { Text = "删除", Width = 64, Height = 30, Font = new Font(Font.FontFamily, 8.5f), Margin = Padding.Empty };
        delete.Click += (_, _) => Delete(row);
        numberBox.Controls.Add(number);
        numberBox.Controls.Add(delete);
        panel.Controls.Add(numberBox, 0, 0);

        var date = new TextBox { Text = row.Date, Width = 112, PlaceholderText = "年-月-日", Margin = new Padding(0, 5, 4, 0) };
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
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 37));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 27));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var purpose = new TextBox { Text = row.Purpose, Dock = DockStyle.Top, PlaceholderText = "填写用途" };
        purpose.TextChanged += (_, _) => { if (_settingValues) return; Remember(); row.Purpose = purpose.Text; MarkEdited(row, "purpose"); UpdateSummary(); };
        nameBox.Controls.Add(purpose, 0, 0);
        var categoryLine = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = true, AutoScroll = true };
        var category = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 98 };
        category.Items.AddRange(Categories);
        category.SelectedItem = Categories.Contains(row.Category) ? row.Category : "待分类";
        var filename = new Label { Text = string.IsNullOrEmpty(row.OriginalFilename) ? Path.GetFileName(row.ImagePath) : row.OriginalFilename, AutoEllipsis = true, ForeColor = Color.DimGray, Width = 95, Height = 28, TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(8, 0, 0, 0) };
        var recognizedText = new Button { Text = "识别文字", AutoSize = true, Enabled = false, Font = new Font(Font.FontFamily, 8.5f), Margin = new Padding(3, 0, 0, 0) };
        recognizedText.Click += (_, _) => ShowRecognizedText(row);
        categoryLine.Controls.Add(category);
        categoryLine.Controls.Add(filename);
        categoryLine.Controls.Add(recognizedText);
        var aiButton = new Button { Text = "AI 辅助", AutoSize = true, Font = new Font(Font.FontFamily, 8.5f) };
        aiButton.Click += async (_, _) => {
            if (row.Pending || !AppSettings.Current.AiEnabled) { MessageBox.Show(this, "请等待当前识别完成，或先在设置中启用 AI。", "AI 辅助"); return; }
            Remember(); row.Pending = true; RefreshRow(row);
            try { await SemanticClassifier.AssistAsync(row, _lifetime.Token, explicitlyRequested: true); }
            catch (Exception ex) { row.AiNote = ex.Message; }
            finally { row.Pending = false; if (_expenses.Contains(row)) { RefreshRow(row); UpdateSummary(); } }
        };
        categoryLine.Controls.Add(aiButton);
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
        amountBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        amountBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
        amountBox.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var amount = new TextBox { Text = row.Amount?.ToString("0.00", CultureInfo.InvariantCulture) ?? "", Width = 145, PlaceholderText = "金额", Margin = new Padding(0, 5, 0, 0) };
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
        amountBox.Controls.Add(candidates, 0, 2);
        panel.Controls.Add(amountBox, 4, 0);

        panel.MouseDown += (_, e) => { SelectRow(row.Id); _dragStart = e.Location; };
        panel.MouseMove += (_, e) => StartRowDrag(panel, row, e.Location, e.Button);
        number.MouseDown += (_, e) => { SelectRow(row.Id); _dragStart = e.Location; };
        number.MouseMove += (_, e) => StartRowDrag(number, row, e.Location, e.Button);
        foreach (var control in new Control[] { numberBox, number, date, nameBox, purpose, categoryLine, category, filename, recognizedText, warning, confirmed, image, amountBox, amount, candidateHint, candidates, delete })
        {
            control.MouseDown += (_, _) => SelectRow(row.Id);
            EnableDrop(control);
        }
        foreach (var handle in new Control[] { numberBox, filename, warning, image })
        {
            handle.MouseDown += (_, e) => _dragStart = e.Location;
            handle.MouseMove += (_, e) => StartRowDrag(handle, row, e.Location, e.Button);
        }
        EnableDrop(panel);
        _rows.Controls.Add(panel);
        _controls[row.Id] = new RowControls(panel, number, date, purpose, category, warning, confirmed, amount, image, recognizedText, candidateHint, candidates);
        panel.Click += (_, _) => SelectRow(row.Id);
    }

    private static Bitmap LoadPreview(string path)
    {
        using var stream = new MemoryStream(ToPng(path));
        using var source = new Bitmap(stream);
        return new Bitmap(source);
    }

    private void ShowPreview(ExpenseRow row)
    {
        try
        {
            using var preview = new Form { Text = Path.GetFileName(row.ImagePath), WindowState = FormWindowState.Maximized, BackColor = Color.FromArgb(25, 28, 34), FormBorderStyle = FormBorderStyle.None, KeyPreview = true, Cursor = Cursors.Hand };
            using var image = LoadPreview(row.ImagePath);
            var picture = new PictureBox { Dock = DockStyle.Fill, Image = image, SizeMode = PictureBoxSizeMode.Zoom, Cursor = Cursors.Hand };
            picture.Click += (_, _) => preview.Close();
            preview.Click += (_, _) => preview.Close();
            preview.KeyDown += (_, e) => { if (e.KeyCode is Keys.Escape or Keys.Space) preview.Close(); };
            preview.Controls.Add(picture);
            preview.ShowDialog(this);
        }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "无法预览", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

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
        var edited = row.Edited;
        if (edited?.Contains("date") != true) ui.Date.Text = row.Date;
        if (edited?.Contains("purpose") != true) ui.Purpose.Text = row.Purpose;
        if (edited?.Contains("category") != true) ui.Category.SelectedItem = row.Category;
        if (edited?.Contains("amount") != true) ui.Amount.Text = row.Amount?.ToString("0.00", CultureInfo.InvariantCulture) ?? "";
        ui.Warning.Text = row.Pending ? "正在识别…" : row.Status + (row.Issues.Count > 0 ? " · " + string.Join("；", row.Issues) : "") + (string.IsNullOrEmpty(row.AiNote) ? "" : " · " + row.AiNote);
        ui.Confirmed.Visible = !row.Duplicate && !row.Pending;
        ui.Confirmed.Checked = row.Confirmed;
        ui.RecognizedText.Enabled = !string.IsNullOrWhiteSpace(row.RecognizedText);
        ui.Panel.Height = row.AmountCandidates.Count > 0 ? 225 : 162;
        ui.CandidateHint.Visible = row.AmountCandidates.Count > 0 && row.Amount == null && !row.Duplicate;
        ui.Candidates.Visible = ui.CandidateHint.Visible;
        if (ui.Candidates.Controls.Count != row.AmountCandidates.Count)
        {
            foreach (Control old in ui.Candidates.Controls.Cast<Control>().ToArray()) old.Dispose();
            ui.Candidates.Controls.Clear();
            foreach (var candidate in row.AmountCandidates)
            {
                var button = new Button { Width = 137, Height = 26, Margin = new Padding(0, 0, 0, 2) };
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
        row.Edited.Add(field);
    }

    private void SelectRow(Guid id)
    {
        _selected = id;
        var expense = _expenses.FirstOrDefault(row => row.Id == id);
        _preview.Image?.Dispose(); _preview.Image = null;
        if (expense != null) { try { _preview.Image = LoadPreview(expense.ImagePath); _previewTitle.Text = Path.GetFileName(expense.ImagePath) + "（点击放大）"; } catch { _previewTitle.Text = "截图无法读取"; } }
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
        if (_selected == row.Id) _selected = null;
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

    private int RowWidth() => Math.Max(620, _rows.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 6);
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
        _blocker.Text = Blocker() ?? "可导出";
        _export.Enabled = Blocker() == null;
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

    private void EnableDropTree(Control parent)
    {
        EnableDrop(parent);
        foreach (Control child in parent.Controls) EnableDropTree(child);
    }
    private void Remember()
    {
        if (_loadingProject || _project == null) return;
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
        if (!SaveCurrent()) return;
        _loadingProject = true;
        foreach (var ui in _controls.Values) { ui.Image.Image?.Dispose(); ui.Panel.Dispose(); }
        _rows.Controls.Clear(); _controls.Clear();
        _project = project; _expenses = project.Expenses; _title.Text = project.Title;
        _selected = null;
        if (clearUndo) _undo.Clear();
        _undoButton.Enabled = _undo.Count > 0;
        foreach (var row in _expenses) { AddRow(row); RefreshRow(row); }
        Renumber(); UpdateSummary();
        _loadingProject = false;
        RefreshProjects(); ShowOrders();
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
        try { _saveTimer.Stop(); var deletedId = _project.Id; _store.Delete(_project); await _invoices.DetachProjectAsync(deletedId); _dirty = false; if (_store.Projects.Count == 0) _store.Create(); LoadProject(_store.Projects[0]); }
        catch (Exception ex) { MessageBox.Show(this, "删除已停止：" + ex.Message, "无法移入回收站"); }
    }
    private void RestoreWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    private void ShowOrders() { _invoiceWorkspace.Visible = false; _orderSplit.Visible = true; _orderSplit.BringToFront(); }
    private void ShowInbox() { RestoreWindow(); _orderSplit.Visible = false; _invoiceWorkspace.Visible = true; _invoiceWorkspace.ShowInbox(); _invoiceWorkspace.BringToFront(); }
    private void ShowProjectInvoices() { if (!SaveCurrent()) return; _orderSplit.Visible = false; _invoiceWorkspace.Visible = true; _invoiceWorkspace.ShowProject(_project); _invoiceWorkspace.BringToFront(); }
    private async void OpenSettings()
    {
        using var settings = new SettingsForm(_tessdataDirectory, _invoices);
        if (settings.ShowDialog(this) == DialogResult.OK) { await _background.SettingsChangedAsync(); }
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
