using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.VisualBasic.FileIO;

namespace ReimburseApp;

public sealed record InvoiceRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string StoredFilename { get; set; } = "";
    public string OriginalFilename { get; set; } = "";
    public string Fingerprint { get; set; } = "";
    public DateTimeOffset ReceivedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset LastAccessedAt { get; set; } = DateTimeOffset.Now;
    public string Source { get; set; } = "手动导入";
    public string MailId { get; set; } = "";
    public MailAttachmentRef? Remote { get; set; }
    public decimal? Amount { get; set; }
    public string? Warning { get; set; }
    public bool Accepted { get; set; }
    public string Reason { get; set; } = "";
    public int PolicyRevision { get; set; }
    public string BuyerTitle { get; set; } = "";
    public string SellerTitle { get; set; } = "";
    public string ItemDescription { get; set; } = "";
    public Guid? ProjectId { get; set; }
    public string? ProjectFile { get; set; }
    public decimal? ProjectAmount { get; set; }
    public string? ProjectWarning { get; set; }
    public bool AutoDownloadPending { get; set; }
    public bool DeletedFromInbox { get; set; }
    public bool IsInvoice => Accepted && PolicyRevision == InvoiceRecognition.PolicyRevision;
}

public sealed class InvoiceRepository
{
    private sealed class Snapshot
    {
        public Snapshot() { }
        public List<InvoiceRecord> Items { get; set; } = [];
        public HashSet<string> Dismissed { get; set; } = [];
        public Dictionary<string, List<Guid>> Archives { get; set; } = [];
        public bool CleanupPaused { get; set; }
    }
    private readonly string _directory;
    private readonly string _files;
    private readonly string _tessdata;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly HashSet<Guid> _busy = [];
    private Snapshot _snapshot;
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    public event EventHandler? Changed;
    public event EventHandler<string>? AutomaticCleanupFailed;
    public IReadOnlyList<InvoiceRecord> Items => _snapshot.Items.Where(i => !i.DeletedFromInbox).ToList();
    public bool IsBusy(Guid id) => _busy.Contains(id);
    public bool CleanupPaused => _snapshot.CleanupPaused;
    public string LastDownloadError { get; private set; } = "";
    public long CacheBytes => CacheEntries().Sum(i => new FileInfo(SourcePath(i)).Length);

    public InvoiceRepository(string tessdataDirectory) : this(tessdataDirectory, AppPaths.Invoices) { }
    internal InvoiceRepository(string tessdataDirectory, string directory)
    {
        _tessdata = tessdataDirectory;
        _directory = directory;
        _files = Path.Combine(directory, "files");
        Directory.CreateDirectory(_files);
        var path = Path.Combine(directory, "invoices.json");
        _snapshot = File.Exists(path) ? JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(path), Json) ?? throw new InvalidDataException("发票箱资料为空，已停止写入。") : new();
    }

    public IReadOnlyList<InvoiceRecord> ForProject(Guid id) => _snapshot.Items.Where(i => i.ProjectId == id && i.IsInvoice).Select(i => i with { Amount = i.ProjectAmount, Warning = i.ProjectWarning }).ToList();
    public bool IsDownloaded(InvoiceRecord item) => File.Exists(SourcePath(item));
    public string SourcePath(InvoiceRecord item) => SafePath(_files, item.StoredFilename);
    public string ProjectPath(InvoiceRecord item) => item.ProjectId is Guid id && item.ProjectFile != null
        ? SafePath(Path.Combine(AppPaths.Projects, id.ToString(), "invoices"), item.ProjectFile) : throw new InvalidOperationException("该发票尚未加入项目。");
    private static string SafePath(string directory, string filename)
    {
        if (string.IsNullOrWhiteSpace(filename) || filename != Path.GetFileName(filename) || filename is "." or ".." || filename.Contains('/') || filename.Contains('\\')) throw new InvalidDataException("发票文件路径无效，操作已停止。");
        return Path.Combine(directory, filename);
    }
    private static string Key(MailAttachmentRef r) => $"{r.Account}|{r.UidValidity}|{r.Uid}|{r.PartId}";
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    private static bool Supported(string filename) => new[] { ".pdf", ".png", ".jpg", ".jpeg", ".heic", ".heif" }.Contains(Path.GetExtension(filename).ToLowerInvariant());
    private void Notify() => Changed?.Invoke(this, EventArgs.Empty);
    private void Save()
    {
        var destination = Path.Combine(_directory, "invoices.json");
        var temporary = destination + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(_snapshot, Json));
        File.Move(temporary, destination, true);
        Notify();
    }

    public async Task RegisterMailAsync(InvoiceMailEnvelope message, bool automaticallyDownload)
    {
        await _gate.WaitAsync();
        try
        {
            foreach (var attachment in message.Attachments)
            {
                var key = Key(attachment.Reference);
                if (_snapshot.Dismissed.Contains(key) || _snapshot.Archives.ContainsKey(key) || _snapshot.Items.Any(i => i.Remote != null && Key(i.Remote) == key) || !InvoiceRecognition.ShouldList(attachment.Filename, message.Subject)) continue;
                if (!Supported(attachment.Filename) && !Path.GetExtension(attachment.Filename).Equals(".zip", StringComparison.OrdinalIgnoreCase)) continue;
                var item = new InvoiceRecord { OriginalFilename = Path.GetFileName(attachment.Filename), Remote = attachment.Reference, ReceivedAt = message.ReceivedAt, LastAccessedAt = message.ReceivedAt, Source = message.Sender + " · " + message.Subject, MailId = message.Id, Fingerprint = "remote:" + key, AutoDownloadPending = automaticallyDownload, Amount = InvoiceRecognition.AmountInFilename(attachment.Filename) };
                item.StoredFilename = item.Id + Path.GetExtension(item.OriginalFilename).ToLowerInvariant();
                _snapshot.Items.Add(item);
            }
            Save();
        }
        finally { _gate.Release(); }
    }

    public async Task ImportAsync(IEnumerable<string> paths)
    {
        await _gate.WaitAsync();
        try
        {
            foreach (var path in paths)
            {
                var bytes = await File.ReadAllBytesAsync(path);
                if (Path.GetExtension(path).Equals(".zip", StringComparison.OrdinalIgnoreCase)) await ImportArchive(bytes, DateTimeOffset.Now, "手动导入", "");
                else await ImportData(bytes, Path.GetFileName(path), DateTimeOffset.Now, "手动导入", "");
            }
        }
        finally { _gate.Release(); }
        await MaintainCacheAsync();
    }

    private async Task<InvoiceRecord> ImportData(byte[] bytes, string name, DateTimeOffset date, string source, string mail)
    {
        if (!Supported(name)) throw new InvalidDataException("不支持的发票格式：" + name);
        if (bytes.Length is 0 or > 40 * 1024 * 1024) throw new InvalidDataException("附件为空或超过 40 MB。");
        var fingerprint = Hash(bytes);
        var existing = _snapshot.Items.FirstOrDefault(i => i.Fingerprint == fingerprint);
        if (existing != null)
        {
            if (existing.PolicyRevision != InvoiceRecognition.PolicyRevision)
            {
                if (!IsDownloaded(existing)) await File.WriteAllBytesAsync(SourcePath(existing), bytes);
                await Recognize(existing);
            }
            return existing;
        }
        var item = new InvoiceRecord { OriginalFilename = Path.GetFileName(name), Fingerprint = fingerprint, ReceivedAt = date, LastAccessedAt = date, Source = source, MailId = mail, Amount = InvoiceRecognition.AmountInFilename(name) };
        item.StoredFilename = item.Id + Path.GetExtension(name).ToLowerInvariant();
        await File.WriteAllBytesAsync(SourcePath(item), bytes);
        _snapshot.Items.Add(item);
        Save();
        await Recognize(item);
        return item;
    }

    private async Task<HashSet<Guid>> ImportArchive(byte[] bytes, DateTimeOffset date, string source, string mail)
    {
        if (bytes.Length is 0 or > 40 * 1024 * 1024) throw new InvalidDataException("压缩包为空或超过 40 MB。");
        using var input = new MemoryStream(bytes, false);
        using var archive = new ZipArchive(input, ZipArchiveMode.Read);
        if (archive.Entries.Count > 500) throw new InvalidDataException("压缩包文件过多，请分批导入。");
        var ids = new HashSet<Guid>();
        long total = 0;
        foreach (var entry in archive.Entries)
        {
            if (!Supported(entry.Name) || entry.FullName.Split('/').Contains("__MACOSX") || entry.Name.StartsWith("._")) continue;
            if (entry.Length > 40 * 1024 * 1024 || total + entry.Length > 100 * 1024 * 1024) throw new InvalidDataException("压缩包展开后超过大小上限。");
            using var stream = entry.Open();
            using var content = new MemoryStream();
            var buffer = new byte[81920];
            int read;
            while ((read = await stream.ReadAsync(buffer)) > 0)
            {
                if (content.Length + read > 40 * 1024 * 1024 || total + content.Length + read > 100 * 1024 * 1024) throw new InvalidDataException("压缩包展开后超过大小上限。");
                await content.WriteAsync(buffer.AsMemory(0, read));
            }
            total += content.Length;
            ids.Add((await ImportData(content.ToArray(), entry.Name, date, source, mail)).Id);
        }
        return ids;
    }

    private async Task Recognize(InvoiceRecord item)
    {
        _busy.Add(item.Id); Notify();
        try
        {
            var source = IsDownloaded(item) ? SourcePath(item) : ProjectPath(item);
            var reading = await Task.Run(() => InvoiceRecognition.Read(source, _tessdata));
            item.Accepted = reading.Accepted;
            item.Reason = reading.Reason;
            item.PolicyRevision = InvoiceRecognition.PolicyRevision;
            if (item.Amount == null) item.Amount = reading.Amount;
            if (string.IsNullOrWhiteSpace(item.BuyerTitle)) item.BuyerTitle = reading.Buyer;
            item.SellerTitle = reading.Seller;
            item.ItemDescription = reading.Item;
            item.Warning = item.Amount is > 0 ? null : "未识别到价税合计，请手动填写。";
            Save();
        }
        finally { _busy.Remove(item.Id); Notify(); }
    }

    public async Task RevalidateAsync()
    {
        await _gate.WaitAsync();
        try
        {
            foreach (var item in _snapshot.Items.Where(i => i.PolicyRevision != InvoiceRecognition.PolicyRevision && (IsDownloaded(i) || i.ProjectId != null && i.ProjectFile != null && File.Exists(ProjectPath(i)))).ToList())
                await Recognize(item);
        }
        finally { _gate.Release(); }
    }

    public async Task<HashSet<Guid>> DownloadAsync(Guid id)
    {
        await _gate.WaitAsync();
        HashSet<Guid> ids;
        try { ids = await DownloadCore(id); }
        finally { _gate.Release(); }
        await MaintainCacheAsync(false, ids);
        return ids;
    }

    private async Task<HashSet<Guid>> DownloadCore(Guid id)
    {
        var item = _snapshot.Items.FirstOrDefault(i => i.Id == id) ?? throw new InvalidOperationException("发票已移除。");
        _busy.Add(id); Notify();
        try
        {
            if (!IsDownloaded(item))
            {
                if (item.Remote == null) throw new FileNotFoundException("本地发票已丢失，请重新导入。");
                var bytes = await MailService.DownloadAttachmentAsync(item.Remote);
                if (bytes.Length is 0 or > 40 * 1024 * 1024) throw new InvalidDataException("附件为空或超过 40 MB。");
                if (Path.GetExtension(item.OriginalFilename).Equals(".zip", StringComparison.OrdinalIgnoreCase))
                {
                    var children = await ImportArchive(bytes, item.ReceivedAt, item.Source, item.MailId);
                    _snapshot.Archives[Key(item.Remote)] = children.ToList();
                    _snapshot.Items.Remove(item);
                    Save();
                    return children;
                }
                await File.WriteAllBytesAsync(SourcePath(item), bytes);
                item.Fingerprint = Hash(bytes);
                Save();
            }
            if (item.PolicyRevision != InvoiceRecognition.PolicyRevision || item.Amount == null || item.BuyerTitle.Length == 0) await Recognize(item);
            if (_snapshot.Items.Any(other => other.Id != item.Id && other.Fingerprint == item.Fingerprint && IsDownloaded(other)))
                item.Warning = "重复发票，发票箱中已有相同文件。";
            item.AutoDownloadPending = false;
            item.LastAccessedAt = DateTimeOffset.Now;
            Save();
            return [id];
        }
        finally { _busy.Remove(id); Notify(); }
    }

    public async Task<(int accepted, int failed)> DownloadPendingAsync(string account, Func<bool> shouldContinue)
    {
        var accepted = new HashSet<Guid>();
        var failed = 0;
        var ids = Items.Where(i => i.AutoDownloadPending && i.Remote?.Account == account).Select(i => i.Id).ToList();
        foreach (var id in ids)
        {
            if (!shouldContinue()) break;
            if (IsBusy(id)) continue;
            try
            {
                var downloaded = await DownloadAsync(id);
                accepted.UnionWith(Items.Where(i => downloaded.Contains(i.Id) && i.IsInvoice).Select(i => i.Id));
            }
            catch (Exception ex) { failed++; LastDownloadError = ex.Message; }
        }
        return (accepted.Count, failed);
    }

    public async Task AssignAsync(IEnumerable<Guid> ids, Guid projectId, bool allowIncomplete = false)
    {
        await _gate.WaitAsync();
        var added = new List<(InvoiceRecord item, string path)>();
        try
        {
            foreach (var id in ids.Distinct())
            {
                var item = _snapshot.Items.FirstOrDefault(i => i.Id == id && !i.DeletedFromInbox) ?? throw new InvalidOperationException("发票不存在。");
                if (!item.IsInvoice) throw new InvalidOperationException("附件未通过电子普通发票自动检查，不能加入项目。");
                if (item.ProjectId == projectId) continue;
                if (item.ProjectId != null || _snapshot.Items.Any(i => i.Id != id && i.Fingerprint == item.Fingerprint && i.ProjectId != null)) throw new InvalidOperationException("该发票已加入项目，不能重复报销。");
                if (!allowIncomplete && (item.Amount is not > 0 || item.Warning != null)) throw new InvalidOperationException("请先确认发票金额：" + item.OriginalFilename);
                await DownloadCore(id);
                var directory = Path.Combine(AppPaths.Projects, projectId.ToString(), "invoices");
                Directory.CreateDirectory(directory);
                var name = Guid.NewGuid() + Path.GetExtension(item.OriginalFilename).ToLowerInvariant();
                var destination = SafePath(directory, name);
                File.Copy(SourcePath(item), destination);
                item.ProjectId = projectId; item.ProjectFile = name; item.ProjectAmount = item.Amount; item.ProjectWarning = item.Warning;
                added.Add((item, destination));
            }
            Save();
        }
        catch
        {
            // Keep successfully copied invoices attached rather than orphaning or deleting project data.
            if (added.Count > 0) Save();
            throw;
        }
        finally { _gate.Release(); }
    }

    public async Task UpdateAsync(Guid id, string amount, string buyer, bool projectOnly = false)
    {
        if (!decimal.TryParse(amount, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var value) || value <= 0 || !System.Text.RegularExpressions.Regex.IsMatch(amount.Trim(), @"^\d+(?:\.\d{1,2})?$")) throw new InvalidOperationException("请填写大于 0、最多两位小数的金额。");
        await _gate.WaitAsync();
        try
        {
            var item = _snapshot.Items.First(i => i.Id == id);
            if (!item.IsInvoice) throw new InvalidOperationException("该附件未通过发票检查。");
            if (projectOnly)
            {
                if (item.ProjectId == null) throw new InvalidOperationException("发票已移出项目。");
                item.ProjectAmount = value; item.ProjectWarning = null;
            }
            else
            {
                if (item.ProjectId != null) throw new InvalidOperationException("已加入项目的发票不能在发票箱修改。");
                item.Amount = value; item.BuyerTitle = buyer.Trim(); item.Warning = null;
            }
            Save();
        }
        finally { _gate.Release(); }
    }

    public async Task RemoveFromProjectAsync(Guid id)
    {
        await _gate.WaitAsync();
        try
        {
            var item = _snapshot.Items.First(i => i.Id == id);
            var file = ProjectPath(item);
            if (File.Exists(file)) Recycle(file);
            item.ProjectId = null; item.ProjectFile = null; item.ProjectAmount = null; item.ProjectWarning = null;
            if (item.DeletedFromInbox) _snapshot.Items.Remove(item);
            Save();
        }
        finally { _gate.Release(); }
    }

    public async Task DetachProjectAsync(Guid projectId)
    {
        await _gate.WaitAsync();
        try
        {
            foreach (var item in _snapshot.Items.Where(i => i.ProjectId == projectId)) { item.ProjectId = null; item.ProjectFile = null; item.ProjectAmount = null; item.ProjectWarning = null; }
            _snapshot.Items.RemoveAll(i => i.DeletedFromInbox && i.ProjectId == null);
            Save();
        }
        finally { _gate.Release(); }
    }

    public async Task DeleteAsync(IEnumerable<Guid> ids)
    {
        await _gate.WaitAsync();
        try
        {
            foreach (var id in ids.ToList())
            {
                var item = _snapshot.Items.FirstOrDefault(i => i.Id == id);
                if (item == null) continue;
                if (IsDownloaded(item)) Recycle(SourcePath(item));
                if (item.Remote != null) _snapshot.Dismissed.Add(Key(item.Remote));
                if (item.ProjectId == null) _snapshot.Items.Remove(item);
                else { item.DeletedFromInbox = true; item.AutoDownloadPending = false; }
                Save();
            }
        }
        finally { _gate.Release(); }
    }

    public async Task<string> ExportAsync(Guid projectId, string parent)
    {
        await _gate.WaitAsync();
        try
        {
            var selected = ForProject(projectId);
            if (selected.Count == 0) throw new InvalidOperationException("请先加入发票。");
            foreach (var item in selected)
                if (item.Amount is not > 0 || item.Warning != null || !File.Exists(ProjectPath(item))) throw new InvalidOperationException("请先补全发票金额或文件：" + item.OriginalFilename);
            var name = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + "-" + selected.Sum(i => i.Amount ?? 0).ToString("0.00", CultureInfo.InvariantCulture);
            var destination = Path.Combine(parent, name);
            for (var n = 2; Directory.Exists(destination) || File.Exists(destination); n++) destination = Path.Combine(parent, name + "(" + n + ")");
            Directory.CreateDirectory(destination);
            for (var index = 0; index < selected.Count; index++)
            {
                var item = selected[index];
                var invalid = Path.GetInvalidFileNameChars();
                var original = new string(Path.GetFileName(item.OriginalFilename).Select(c => invalid.Contains(c) ? '_' : c).ToArray()).TrimEnd('.', ' ');
                var filename = (index + 1).ToString("D3", CultureInfo.InvariantCulture) + "_" + original;
                File.Copy(ProjectPath(item), Path.Combine(destination, filename));
            }
            return destination;
        }
        finally { _gate.Release(); }
    }

    private IEnumerable<InvoiceRecord> CacheEntries()
    {
        if ((File.GetAttributes(_files) & FileAttributes.ReparsePoint) != 0) throw new IOException("缓存目录是链接，已停止清理。");
        return _snapshot.Items.Where(i => !i.DeletedFromInbox && i.Remote != null && IsDownloaded(i) && (File.GetAttributes(SourcePath(i)) & FileAttributes.ReparsePoint) == 0).ToList();
    }
    public async Task RetryCacheCleanupAsync()
    {
        await _gate.WaitAsync();
        try { _snapshot.CleanupPaused = false; Save(); }
        finally { _gate.Release(); }
        await MaintainCacheAsync();
    }
    public async Task MaintainCacheAsync(bool clearAll = false) => await MaintainCacheAsync(clearAll, []);
    private async Task MaintainCacheAsync(bool clearAll, HashSet<Guid>? protecting)
    {
        await _gate.WaitAsync();
        try
        {
            if (_snapshot.CleanupPaused && !clearAll) return;
            if (clearAll) _snapshot.CleanupPaused = false;
            var entries = CacheEntries().OrderBy(i => i.LastAccessedAt).ToList();
            long remaining = entries.Sum(i => new FileInfo(SourcePath(i)).Length);
            var limit = AppSettings.Current.CacheLimitMb * 1_000_000;
            foreach (var item in entries)
            {
                if (!clearAll && remaining <= limit) break;
                if (_busy.Contains(item.Id) || protecting?.Contains(item.Id) == true) continue;
                var bytes = new FileInfo(SourcePath(item)).Length;
                try { Recycle(SourcePath(item)); }
                catch (Exception ex)
                {
                    _snapshot.CleanupPaused = true; Save();
                    AutomaticCleanupFailed?.Invoke(this, ex.Message);
                    throw;
                }
                remaining -= bytes;
            }
            Save();
        }
        finally { _gate.Release(); }
    }
    private static void Recycle(string path) => FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin, UICancelOption.ThrowException);
}
