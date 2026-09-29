using System.Drawing.Imaging;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using ImageMagick;

namespace ReimburseApp;

public sealed class MainForm : Form
{
    private static readonly string[] Categories = ["待分类", "交通", "餐食", "住宿", "采购", "其他"];
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".heic" };
    private readonly string _tessdataDirectory;
    private readonly List<ExpenseRow> _expenses = [];
    private readonly Dictionary<Guid, RowControls> _controls = [];
    private readonly Dictionary<Guid, HashSet<string>> _edited = [];
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
        Text = "报销单助手";
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        MinimumSize = new Size(1030, 620);
        Size = new Size(1180, 760);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 10);
        BackColor = Color.White;
        AllowDrop = true;

        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Padding = new Padding(14, 12, 14, 10) };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 39));
        Controls.Add(root);

        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, FlowDirection = FlowDirection.LeftToRight };
        toolbar.Controls.Add(new Label { Text = "报销单标题", AutoSize = true, Margin = new Padding(0, 8, 10, 0) });
        toolbar.Controls.Add(_title);
        var import = new Button { Text = "导入截图", AutoSize = true, Margin = new Padding(18, 0, 8, 0) };
        import.Click += (_, _) => ChooseImages();
        toolbar.Controls.Add(import);
        _export.Click += (_, _) => Export();
        toolbar.Controls.Add(_export);
        root.Controls.Add(toolbar, 0, 0);

        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5, BackColor = Color.FromArgb(241, 244, 248), Padding = new Padding(8, 0, 18, 0) };
        SetColumns(header);
        var titles = new[] { "序号", "日期", "名称", "图片", "金额" };
        for (var i = 0; i < titles.Length; i++)
        {
            var label = new Label { Text = titles[i], Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Font = new Font(Font, FontStyle.Bold) };
            header.Controls.Add(label, i, 0);
            EnableDrop(label);
        }
        root.Controls.Add(header, 0, 1);
        root.Controls.Add(_rows, 0, 2);

        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 53));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 47));
        footer.Controls.Add(_summary, 0, 0);
        footer.Controls.Add(_blocker, 1, 0);
        root.Controls.Add(footer, 0, 3);

        _title.TextChanged += (_, _) => UpdateSummary();
        _rows.Resize += (_, _) => ResizeRows();
        EnableDrop(this);
        EnableDrop(root);
        EnableDrop(toolbar);
        EnableDrop(import);
        EnableDrop(_export);
        EnableDrop(_title);
        EnableDrop(header);
        EnableDrop(footer);
        EnableDrop(_summary);
        EnableDrop(_blocker);
        EnableDrop(_rows);
        UpdateSummary();
    }

    private static void SetColumns(TableLayoutPanel panel)
    {
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 135));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 165));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 160));
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
                var duplicate = _expenses.Any(row => row.Fingerprint == fingerprint && !row.Duplicate);
                var row = new ExpenseRow
                {
                    ImagePath = path,
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
        try
        {
            var suggestion = await Task.Run(() => Recognition.FromPng(ToPng(row.ImagePath), _tessdataDirectory));
            if (!_expenses.Contains(row)) return;
            var edited = _edited.GetValueOrDefault(row.Id);
            if (edited?.Contains("amount") != true) row.Amount = suggestion.Amount;
            if (edited?.Contains("date") != true) row.Date = suggestion.Date ?? "";
            if (edited?.Contains("category") != true) row.Category = suggestion.Category;
            if (edited?.Contains("purpose") != true) row.Purpose = suggestion.Purpose;
            row.Warning = suggestion.Warning;
            row.RecognizedText = suggestion.RecognizedText;
            row.AmountCandidates = suggestion.AmountCandidates;
        }
        catch (Exception ex) { row.Warning = $"识别失败：{ex.Message}。请手动填写并确认。"; }
        finally
        {
            row.Pending = false;
            if (_expenses.Contains(row)) RefreshRow(row);
            UpdateSummary();
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

        var date = new TextBox { Text = row.Date, Width = 120, PlaceholderText = "年-月-日", Margin = new Padding(0, 5, 4, 0) };
        date.TextChanged += (_, _) => { if (_settingValues) return; row.Date = date.Text; MarkEdited(row, "date"); UpdateSummary(); };
        panel.Controls.Add(date, 1, 0);

        var nameBox = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 4, ColumnCount = 1 };
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 37));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Absolute, 27));
        nameBox.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var purpose = new TextBox { Text = row.Purpose, Dock = DockStyle.Top, PlaceholderText = "填写用途" };
        purpose.TextChanged += (_, _) => { if (_settingValues) return; row.Purpose = purpose.Text; MarkEdited(row, "purpose"); UpdateSummary(); };
        nameBox.Controls.Add(purpose, 0, 0);
        var categoryLine = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        var category = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 98 };
        category.Items.AddRange(Categories);
        category.SelectedItem = Categories.Contains(row.Category) ? row.Category : "待分类";
        var filename = new Label { Text = Path.GetFileName(row.ImagePath), AutoEllipsis = true, ForeColor = Color.DimGray, Width = 165, Height = 28, TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(8, 0, 0, 0) };
        var recognizedText = new Button { Text = "识别文字", AutoSize = true, Enabled = false, Font = new Font(Font.FontFamily, 8.5f), Margin = new Padding(3, 0, 0, 0) };
        recognizedText.Click += (_, _) => ShowRecognizedText(row);
        categoryLine.Controls.Add(category);
        categoryLine.Controls.Add(filename);
        categoryLine.Controls.Add(recognizedText);
        nameBox.Controls.Add(categoryLine, 0, 1);
        var warning = new Label { Text = row.Warning ?? "", ForeColor = Color.DarkOrange, AutoEllipsis = true, Dock = DockStyle.Fill };
        nameBox.Controls.Add(warning, 0, 2);
        var confirmed = new CheckBox { Text = "已人工核对", AutoSize = true, Checked = row.Confirmed, Visible = row.Warning != null && !row.Duplicate && !row.Pending };
        confirmed.CheckedChanged += (_, _) => { if (_settingValues) return; row.Confirmed = confirmed.Checked; UpdateSummary(); };
        nameBox.Controls.Add(confirmed, 0, 3);
        category.SelectedIndexChanged += (_, _) =>
        {
            if (_settingValues) return;
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
        var edited = _edited.GetValueOrDefault(row.Id);
        if (edited?.Contains("date") != true) ui.Date.Text = row.Date;
        if (edited?.Contains("purpose") != true) ui.Purpose.Text = row.Purpose;
        if (edited?.Contains("category") != true) ui.Category.SelectedItem = row.Category;
        if (edited?.Contains("amount") != true) ui.Amount.Text = row.Amount?.ToString("0.00", CultureInfo.InvariantCulture) ?? "";
        ui.Warning.Text = row.Warning ?? "";
        ui.Confirmed.Visible = row.Warning != null && !row.Duplicate && !row.Pending;
        ui.Confirmed.Checked = row.Confirmed;
        ui.RecognizedText.Enabled = !string.IsNullOrWhiteSpace(row.RecognizedText);
        ui.Panel.Height = row.AmountCandidates.Count > 0 ? 225 : 162;
        ui.CandidateHint.Visible = row.AmountCandidates.Count > 0 && !row.Duplicate;
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
                    row.Amount = candidate.Amount;
                    row.Confirmed = true;
                    if (_edited.TryGetValue(row.Id, out var fields)) fields.Remove("amount");
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
        if (!_edited.TryGetValue(row.Id, out var fields)) _edited[row.Id] = fields = [];
        fields.Add(field);
    }

    private void SelectRow(Guid id)
    {
        _selected = id;
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
        var row = _expenses[source];
        _expenses.RemoveAt(source);
        _expenses.Insert(target, row);
        _rows.Controls.SetChildIndex(_controls[sourceId].Panel, target);
        Renumber();
        SelectRow(sourceId);
    }

    private void Delete(ExpenseRow row)
    {
        var wasDuplicate = row.Duplicate;
        _expenses.Remove(row);
        _edited.Remove(row.Id);
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
        var unique = _expenses.Where(row => !row.Duplicate).ToList();
        if (unique.Count == 0) return "请先导入截图。";
        for (var i = 0; i < unique.Count; i++)
        {
            var row = unique[i];
            if (row.Pending) return "请等待截图识别完成。";
            if (row.Amount is not > 0) return $"第{i + 1}笔请填写正数金额。";
            if (!DateOnly.TryParseExact(row.Date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _)) return $"第{i + 1}笔请填写有效日期（年-月-日）。";
            if (string.IsNullOrWhiteSpace(row.Purpose)) return $"第{i + 1}笔请填写用途。";
            if (row.Warning != null && !row.Confirmed) return $"第{i + 1}笔请确认识别提示。";
        }
        return null;
    }

    private void UpdateSummary()
    {
        var unique = _expenses.Where(row => !row.Duplicate).ToList();
        var valid = unique.Where(row => !row.Pending && row.Amount is > 0 && (row.Warning == null || row.Confirmed));
        var total = valid.Sum(row => row.Amount ?? 0);
        var pending = unique.Count(row => row.Pending || row.Amount is not > 0 || !DateOnly.TryParseExact(row.Date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _) || string.IsNullOrWhiteSpace(row.Purpose) || row.Warning != null && !row.Confirmed);
        _summary.Text = $"已导入 {_expenses.Count} 张 · 有效 {unique.Count} 笔 · 待核对 {pending} 笔 · 合计 ¥{total:N2}";
        var blocker = Blocker();
        _blocker.Text = blocker ?? "";
        _export.Enabled = blocker == null;
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

    private sealed record RowControls(TableLayoutPanel Panel, Label Number, TextBox Date, TextBox Purpose, ComboBox Category, Label Warning, CheckBox Confirmed, TextBox Amount, PictureBox Image, Button RecognizedText, Label CandidateHint, FlowLayoutPanel Candidates);
}
