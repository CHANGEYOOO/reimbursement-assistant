using System.Diagnostics;
using System.Globalization;
using UglyToad.PdfPig;

namespace ReimburseApp;

public sealed class InvoiceWorkspace : UserControl
{
    private readonly InvoiceRepository _repository;
    private readonly Func<IReadOnlyList<ProjectRecord>> _projects;
    private readonly Func<ProjectRecord?> _currentProject;
    private ProjectRecord? _project;
    private readonly HashSet<Guid> _selected = [];
    private readonly ComboBox _kind = Combo(["发票", "待下载附件", "已排除附件"]);
    private readonly ComboBox _buyer = Combo(["全部抬头", "抬头未知"]);
    private readonly ComboBox _assignment = Combo(["全部状态", "未加入", "已加入"]);
    private readonly CheckBox _dateFilter = new() { Text = "收件日期", AutoSize = true };
    private readonly DateTimePicker _start = new() { Format = DateTimePickerFormat.Short, Width = 120, Value = DateTime.Today.AddMonths(-1) };
    private readonly DateTimePicker _end = new() { Format = DateTimePickerFormat.Short, Width = 120 };
    private readonly Label _heading = new() { AutoSize = true, Font = new Font("Microsoft YaHei UI", 15, FontStyle.Bold) };
    private readonly Label _summary = new() { AutoSize = true, Padding = new Padding(0, 7, 0, 0) };
    private readonly Label _note = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly FlowLayoutPanel _body = new() { Dock = DockStyle.Fill, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = false };
    private readonly FlowLayoutPanel _filters = new() { AutoSize = true, Dock = DockStyle.Fill };
    private readonly Button _join;
    private readonly Button _delete;
    private readonly Button _export;
    private readonly Button _sync;
    private readonly CheckBox _all = new() { Text = "全选当前结果", AutoSize = true, Padding = new Padding(0, 6, 0, 0) };
    private bool _rendering;
    private bool _working;
    public event EventHandler? SyncRequested;

    public InvoiceWorkspace(InvoiceRepository repository, Func<IReadOnlyList<ProjectRecord>> projects, Func<ProjectRecord?> currentProject)
    {
        _repository = repository; _projects = projects; _currentProject = currentProject;
        Dock = DockStyle.Fill; Padding = new Padding(16); BackColor = Color.White;
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5 };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(root);
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        toolbar.Controls.Add(_heading);
        _sync = Button("同步邮箱", (_, _) => SyncRequested?.Invoke(this, EventArgs.Empty)); toolbar.Controls.Add(_sync);
        toolbar.Controls.Add(Button("导入发票", async (_, _) => await Run(Import)));
        _export = Button("导出发票文件夹", async (_, _) => await Run(Export)); toolbar.Controls.Add(_export);
        root.Controls.Add(toolbar, 0, 0);
        foreach (var c in new Control[] { _kind, _buyer, _assignment, _dateFilter, _start, new Label { Text = "至", AutoSize = true, Padding = new Padding(0, 6, 0, 0) }, _end }) _filters.Controls.Add(c);
        root.Controls.Add(_filters, 0, 1);
        foreach (var combo in new[] { _kind, _buyer, _assignment }) combo.SelectedIndexChanged += (_, _) => { if (!_rendering) RefreshView(); };
        _dateFilter.CheckedChanged += (_, _) => RefreshView(); _start.ValueChanged += (_, _) => RefreshView(); _end.ValueChanged += (_, _) => RefreshView();
        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        _all.CheckedChanged += (_, _) =>
        {
            if (_rendering) return;
            var ids = Filtered().Where(i => !_repository.IsBusy(i.Id)).Select(i => i.Id).ToHashSet();
            if (_all.Checked) _selected.UnionWith(ids); else _selected.ExceptWith(ids);
            RefreshView();
        };
        actions.Controls.Add(_all); actions.Controls.Add(_summary);
        _join = Button("加入项目", async (_, _) => await Run(Join)); actions.Controls.Add(_join);
        _delete = Button("删除所选", async (_, _) => await Run(DeleteSelected)); actions.Controls.Add(_delete);
        root.Controls.Add(actions, 0, 2);
        root.Controls.Add(_note, 0, 3); root.Controls.Add(_body, 0, 4);
        _body.Resize += (_, _) => { foreach (Control c in _body.Controls) c.Width = Math.Max(520, _body.ClientSize.Width - 24); };
        AllowDrop = true; _body.AllowDrop = true;
        foreach (var target in new Control[] { this, _body })
        {
            target.DragEnter += (_, e) => { if (e.Data?.GetDataPresent(DataFormats.FileDrop) == true) e.Effect = DragDropEffects.Copy; };
            target.DragDrop += async (_, e) =>
            {
                if (e.Data?.GetData(DataFormats.FileDrop) is string[] files) await Run(async () => await ImportPaths(files));
            };
        }
        _repository.Changed += RepositoryChanged;
        ShowInbox();
    }
    private void RepositoryChanged(object? sender, EventArgs e)
    {
        if (IsDisposed) return;
        if (InvokeRequired) BeginInvoke(RefreshView); else RefreshView();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) _repository.Changed -= RepositoryChanged;
        base.Dispose(disposing);
    }
    private static ComboBox Combo(string[] values)
    {
        var combo = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };
        combo.Items.AddRange(values); combo.SelectedIndex = 0; return combo;
    }
    private static Button Button(string title, EventHandler action)
    {
        var button = new Button { Text = title, AutoSize = true, MinimumSize = new Size(80, 32), Margin = new Padding(6, 0, 0, 4) };
        button.Click += action; return button;
    }
    public void ShowInbox() { _project = null; _selected.Clear(); RefreshView(); }
    public void ShowProject(ProjectRecord project) { _project = project; _selected.Clear(); RefreshView(); }
    private IReadOnlyList<InvoiceRecord> Filtered()
    {
        if (_project != null) return _repository.ForProject(_project.Id).OrderByDescending(i => i.ReceivedAt).ToList();
        return _repository.Items.Where(i => (_kind.Text == "发票" ? i.IsInvoice : _kind.Text == "待下载附件" ? !i.IsInvoice && !_repository.IsDownloaded(i) && i.PolicyRevision == 0 : !i.IsInvoice && (_repository.IsDownloaded(i) || i.PolicyRevision > 0))
            && (_buyer.Text == "全部抬头" || (_buyer.Text == "抬头未知" ? i.BuyerTitle.Length == 0 : i.BuyerTitle == _buyer.Text))
            && (_assignment.Text == "全部状态" || (_assignment.Text == "未加入" ? i.ProjectId == null : i.ProjectId != null))
            && (!_dateFilter.Checked || (i.ReceivedAt.LocalDateTime.Date >= _start.Value.Date && i.ReceivedAt.LocalDateTime.Date <= _end.Value.Date))).OrderByDescending(i => i.ReceivedAt).ToList();
    }
    public void RefreshView()
    {
        if (_rendering || IsDisposed) return;
        _rendering = true;
        try
        {
            var selectedBuyer = _buyer.Text;
            var buyers = new[] { "全部抬头", "抬头未知" }.Concat(_repository.Items.Select(i => i.BuyerTitle).Where(t => t.Length > 0).Distinct().OrderBy(t => t)).ToArray();
            if (!_buyer.Items.Cast<string>().SequenceEqual(buyers)) { _buyer.Items.Clear(); _buyer.Items.AddRange(buyers); _buyer.SelectedItem = buyers.Contains(selectedBuyer) ? selectedBuyer : "全部抬头"; }
            var items = Filtered();
            _heading.Text = _project == null ? "发票箱" : _project.Title + " · 项目发票夹";
            _filters.Visible = _project == null; _sync.Visible = _project == null;
            _join.Visible = _project == null; _export.Visible = _project != null;
            _note.Text = _project == null ? "新收附件自动下载识别。只收录电子普通发票；历史附件在待下载区。" : ProjectSummary(items);
            var chosen = items.Where(i => _selected.Contains(i.Id)).ToList();
            _summary.Text = $"已选 {chosen.Count} 张，合计 ¥{chosen.Where(i => i.Amount is > 0).Sum(i => i.Amount ?? 0):N2}" + (chosen.Any(i => i.Amount is not > 0) ? "（缺金额未计入）" : "");
            var selectable = items.Where(i => !_repository.IsBusy(i.Id)).Select(i => i.Id).ToHashSet();
            _all.Checked = selectable.Count > 0 && selectable.IsSubsetOf(_selected);
            _all.Enabled = !_working && selectable.Count > 0;
            _join.Enabled = !_working && chosen.Any(i => i.ProjectId == null && i.IsInvoice && !_repository.IsBusy(i.Id));
            _delete.Enabled = !_working && chosen.Count > 0; _delete.Text = _project == null ? "删除所选" : "移出项目";
            _export.Enabled = !_working && items.Count > 0;
            var scroll = -_body.AutoScrollPosition.Y;
            _body.SuspendLayout();
            foreach (Control c in _body.Controls.Cast<Control>().ToList()) c.Dispose();
            _body.Controls.Clear();
            foreach (var group in items.GroupBy(i => new DateTime(i.ReceivedAt.LocalDateTime.Year, i.ReceivedAt.LocalDateTime.Month, 1)))
            {
                var eligible = group.Where(i => i.ProjectId == null && i.IsInvoice && !_repository.IsBusy(i.Id)).Select(i => i.Id).ToHashSet();
                var count = eligible.Count(id => _selected.Contains(id));
                var month = new CheckBox { AutoSize = true, ThreeState = true, Text = $"{MonthName(group.Key)} · {group.Count()} 张 · {group.Count(i => i.ProjectId == null && i.IsInvoice)} 张未加入", CheckState = count == 0 ? CheckState.Unchecked : count == eligible.Count ? CheckState.Checked : CheckState.Indeterminate, Enabled = eligible.Count > 0 && !_working, Font = new Font(Font, FontStyle.Bold), Padding = new Padding(0, 12, 0, 4) };
                month.AutoCheck = false;
                month.Click += (_, _) => { if (count == eligible.Count) _selected.ExceptWith(eligible); else _selected.UnionWith(eligible); RefreshView(); };
                _body.Controls.Add(month);
                foreach (var item in group) _body.Controls.Add(Card(item));
            }
            if (items.Count == 0) _body.Controls.Add(new Label { AutoSize = true, Text = "暂无符合条件的发票。可同步邮箱或导入图片、PDF、ZIP。", Padding = new Padding(20) });
            foreach (Control c in _body.Controls) c.Width = Math.Max(520, _body.ClientSize.Width - 24);
            _body.ResumeLayout();
            _body.AutoScrollPosition = new Point(0, scroll);
        }
        finally { _rendering = false; }
    }
    private string ProjectSummary(IReadOnlyList<InvoiceRecord> items)
    {
        var total = items.Where(i => i.Amount is > 0 && i.Warning == null).Sum(i => i.Amount ?? 0);
        var order = _project!.Expenses.Where(e => !e.Duplicate && e.Amount is > 0).Sum(e => e.Amount ?? 0);
        var provisional = _project.Expenses.Any(e => !e.Duplicate && (e.Pending || e.Amount is not > 0 || e.Warning?.Contains("金额") == true && !e.Confirmed));
        return $"发票 {items.Count} 张 · 发票合计 ¥{total:N2} · 订单 ¥{order:N2} · 尚差 ¥{Math.Max(0, order - total):N2}" + (provisional ? "（订单金额暂估）" : "");
    }
    private static string MonthName(DateTime date) => date == new DateTime(DateTime.Now.Year, DateTime.Now.Month, 1) ? "本月" : date == new DateTime(DateTime.Now.Year, DateTime.Now.Month, 1).AddMonths(-1) ? "上月" : date.ToString("yyyy年MM月", CultureInfo.InvariantCulture);
    private Control Card(InvoiceRecord item)
    {
        var card = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(12), Margin = new Padding(0, 0, 0, 10), BackColor = _selected.Contains(item.Id) ? Color.FromArgb(222, 236, 251) : Color.FromArgb(246, 247, 249) };
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = true };
        var check = new CheckBox { Checked = _selected.Contains(item.Id), AutoSize = true, Text = item.SellerTitle.Length > 0 ? item.SellerTitle : item.OriginalFilename, Enabled = !_repository.IsBusy(item.Id) && !_working };
        check.CheckedChanged += (_, _) => { if (check.Checked) _selected.Add(item.Id); else _selected.Remove(item.Id); RefreshView(); };
        row.Controls.Add(check);
        row.Controls.Add(new Label { AutoSize = true, Text = item.Amount is decimal amount ? $"¥{amount:N2}" : "金额待填写", Font = new Font(Font, FontStyle.Bold) });
        card.Controls.Add(row);
        var status = item.ProjectId == null ? "未加入项目" : "已加入 · " + (_projects().FirstOrDefault(p => p.Id == item.ProjectId)?.Title ?? "项目");
        card.Controls.Add(new Label { AutoSize = true, Text = status, ForeColor = item.ProjectId == null ? Color.DimGray : Color.ForestGreen, BackColor = item.ProjectId == null ? card.BackColor : Color.FromArgb(224, 242, 228), Padding = new Padding(5) });
        card.Controls.Add(new Label { AutoSize = true, Text = $"收件日期：{item.ReceivedAt.LocalDateTime:yyyy-MM-dd}　购买方：{(item.BuyerTitle.Length == 0 ? "待识别" : item.BuyerTitle)}" });
        if (item.ItemDescription.Length > 0) card.Controls.Add(new Label { AutoSize = true, Text = "内容：" + item.ItemDescription });
        if (!item.IsInvoice) card.Controls.Add(new Label { AutoSize = true, ForeColor = Color.DarkOrange, Text = _repository.IsDownloaded(item) ? "已排除：" + item.Reason : "待下载识别" });
        if (item.Warning != null) card.Controls.Add(new Label { AutoSize = true, ForeColor = Color.DarkOrange, Text = item.Warning });
        card.Controls.Add(new Label { AutoSize = true, ForeColor = Color.DimGray, Text = "来源：" + item.Source });
        var actions = new FlowLayoutPanel { AutoSize = true, WrapContents = true };
        if (!_repository.IsDownloaded(item) && _project == null) actions.Controls.Add(Button("下载", async (_, _) => await Run(async () => { await _repository.DownloadAsync(item.Id); })));
        actions.Controls.Add(Button("预览", async (_, _) => await Run(async () => await Preview(item))));
        if (item.IsInvoice && (item.ProjectId == null || _project != null)) actions.Controls.Add(Button(_project == null ? "修改金额与抬头" : "修改金额", async (_, _) => await Run(async () => await Edit(item))));
        actions.Controls.Add(Button(_project == null ? "删除" : "移出项目", async (_, _) => await Run(async () => { _selected.Clear(); _selected.Add(item.Id); await DeleteSelected(); })));
        actions.Enabled = !_working && !_repository.IsBusy(item.Id);
        card.Controls.Add(actions);
        return card;
    }
    private async Task Run(Func<Task> action)
    {
        if (_working) return;
        _working = true; RefreshView();
        try { await action(); }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "操作未完成", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        finally { _working = false; RefreshView(); }
    }
    private async Task Import()
    {
        using var dialog = new OpenFileDialog { Filter = "发票文件|*.pdf;*.png;*.jpg;*.jpeg;*.heic;*.heif;*.zip", Multiselect = true };
        if (dialog.ShowDialog(this) == DialogResult.OK) await ImportPaths(dialog.FileNames);
    }
    private async Task ImportPaths(IEnumerable<string> paths)
    {
        var before = _repository.Items.Select(i => i.Id).ToHashSet();
        await _repository.ImportAsync(paths);
        if (_project != null)
        {
            var added = _repository.Items.Where(i => !before.Contains(i.Id) && i.IsInvoice).Select(i => i.Id).ToList();
            await _repository.AssignAsync(added, _project.Id, allowIncomplete: true);
        }
    }
    private async Task Join()
    {
        var projects = _projects();
        if (projects.Count == 0) throw new InvalidOperationException("请先创建报销项目。");
        using var form = new Form { Text = "选择报销项目", Size = new Size(430, 360), StartPosition = FormStartPosition.CenterParent };
        var list = new ListBox { Dock = DockStyle.Fill, DisplayMember = "Title", DataSource = projects.ToList() };
        var current = _currentProject();
        if (current != null) list.SelectedItem = projects.FirstOrDefault(p => p.Id == current.Id);
        var button = new Button { Text = "加入所选项目", Dock = DockStyle.Bottom, Height = 40, DialogResult = DialogResult.OK };
        form.Controls.Add(list); form.Controls.Add(button); form.AcceptButton = button;
        if (form.ShowDialog(this) != DialogResult.OK || list.SelectedItem is not ProjectRecord project) return;
        var ids = Filtered().Where(i => _selected.Contains(i.Id) && i.ProjectId == null && i.IsInvoice && !_repository.IsBusy(i.Id)).Select(i => i.Id).ToList();
        await _repository.AssignAsync(ids, project.Id); _selected.ExceptWith(ids);
    }
    private async Task DeleteSelected()
    {
        var ids = Filtered().Where(i => _selected.Contains(i.Id)).Select(i => i.Id).ToList();
        if (ids.Count == 0) return;
        var message = _project == null ? "删除所选发票箱记录并将缓存移入回收站？项目副本、已导出文件及邮箱原件不受影响。" : "将所选发票移出项目？项目副本将移入回收站，发票箱中的原件保留。";
        if (MessageBox.Show(this, message, "请确认", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        if (_project == null) await _repository.DeleteAsync(ids); else foreach (var id in ids) await _repository.RemoveFromProjectAsync(id);
        _selected.ExceptWith(ids);
    }
    private async Task Edit(InvoiceRecord item)
    {
        using var form = new Form { Text = "修改发票", Size = new Size(520, 205), StartPosition = FormStartPosition.CenterParent };
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(15), FlowDirection = FlowDirection.TopDown };
        var amount = new TextBox { Width = 450, Text = item.Amount?.ToString(CultureInfo.InvariantCulture) ?? "", PlaceholderText = "发票金额" };
        var buyer = new TextBox { Width = 450, Text = item.BuyerTitle, PlaceholderText = "购买方抬头", Visible = _project == null };
        var save = new Button { Text = "保存", DialogResult = DialogResult.OK, AutoSize = true };
        panel.Controls.Add(amount); panel.Controls.Add(buyer); panel.Controls.Add(save); form.Controls.Add(panel); form.AcceptButton = save;
        if (form.ShowDialog(this) == DialogResult.OK) await _repository.UpdateAsync(item.Id, amount.Text, buyer.Text, projectOnly: _project != null);
    }
    private async Task Export()
    {
        if (_project == null) return;
        using var dialog = new FolderBrowserDialog { Description = "选择发票导出位置", UseDescriptionForTitle = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        var destination = await _repository.ExportAsync(_project.Id, dialog.SelectedPath);
        Process.Start(new ProcessStartInfo(destination) { UseShellExecute = true });
    }
    private async Task Preview(InvoiceRecord item)
    {
        string path;
        if (_project != null) path = _repository.ProjectPath(item);
        else
        {
            var ids = await _repository.DownloadAsync(item.Id);
            if (!ids.Contains(item.Id)) return;
            path = _repository.SourcePath(item);
        }
        var pages = 1;
        if (Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase)) { using var pdf = PdfDocument.Open(path); pages = pdf.NumberOfPages; }
        using var form = new Form { Text = item.OriginalFilename, WindowState = FormWindowState.Maximized, BackColor = Color.FromArgb(25, 28, 34), KeyPreview = true };
        var picture = new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Cursor = Cursors.Hand };
        var controls = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 42, BackColor = Color.White };
        var page = 0;
        void LoadPage()
        {
            using var input = new MemoryStream(InvoiceRecognition.PreviewPng(path, page));
            using var image = new Bitmap(input);
            var old = picture.Image; picture.Image = new Bitmap(image); old?.Dispose();
        }
        controls.Controls.Add(Button("上一页", (_, _) => { if (page > 0) { page--; LoadPage(); } }));
        controls.Controls.Add(Button("下一页", (_, _) => { if (page + 1 < pages) { page++; LoadPage(); } }));
        controls.Controls.Add(Button("关闭预览", (_, _) => form.Close())); controls.Visible = pages > 1;
        picture.Click += (_, _) => form.Close(); form.KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) form.Close(); };
        form.Controls.Add(picture); form.Controls.Add(controls);
        LoadPage(); form.ShowDialog(this); picture.Image?.Dispose();
    }
}
