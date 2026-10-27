using System.Text;
using System.Text.RegularExpressions;
using MailKit;
using MailKit.Net.Imap;
using MailKit.Search;
using MailKit.Security;
using MimeKit;

namespace ReimburseApp;

public sealed record MailAttachmentRef(string Account, uint UidValidity, uint Uid, string PartId);
public sealed record MailAttachmentInfo(string Filename, MailAttachmentRef Reference);
public sealed record InvoiceMailEnvelope(string Id, string Subject, string Sender, DateTimeOffset ReceivedAt,
    IReadOnlyList<MailAttachmentInfo> Attachments, bool HasDownloadLink);
public sealed record MailboxManualNotice(string Id, string Subject, string Sender, DateTimeOffset ReceivedAt);

public static class MailService
{
    private const int MaximumBytes = 40 * 1024 * 1024;
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) { ".pdf", ".png", ".jpg", ".jpeg", ".heic", ".heif", ".zip" };

    public static void ValidateCredentials(string address, string password)
    {
        if (!Regex.IsMatch(address.Trim(), @"^[a-z0-9._%+\-]+@(?:qq|vip\.qq|foxmail)\.com$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            throw new InvalidOperationException("请填写有效的 QQ 邮箱地址。");
        if (string.IsNullOrWhiteSpace(password) || password.Any(char.IsControl))
            throw new InvalidOperationException("请填写 QQ 邮箱授权码，授权码不是 QQ 登录密码。");
    }

    public static async Task TestAsync(string address, string password, CancellationToken ct = default)
    {
        using var client = await ConnectAsync(address, password, ct);
        await client.Inbox.OpenAsync(FolderAccess.ReadOnly, ct);
        await client.DisconnectAsync(true, ct);
    }

    public static async Task FetchAsync(string address, string password, DateTimeOffset since, ISet<string> processed,
        Func<InvoiceMailEnvelope, Task> receive, CancellationToken ct = default)
    {
        var account = address.Trim().ToLowerInvariant();
        using var client = await ConnectAsync(account, password, ct);
        var inbox = client.Inbox;
        await inbox.OpenAsync(FolderAccess.ReadOnly, ct);
        var ids = await inbox.SearchAsync(SearchQuery.DeliveredAfter(since.LocalDateTime.Date), ct);
        var remaining = ids.Where(uid => !processed.Contains(MessageId(account, inbox.UidValidity, uid.Id))).ToList();
        for (var offset = 0; offset < remaining.Count; offset += 100)
        {
            ct.ThrowIfCancellationRequested();
            var batch = remaining.Skip(offset).Take(100).ToList();
            var summaries = await inbox.FetchAsync(batch, MessageSummaryItems.UniqueId | MessageSummaryItems.InternalDate | MessageSummaryItems.Envelope | MessageSummaryItems.BodyStructure, ct);
            foreach (var summary in summaries.OrderBy(s => s.UniqueId.Id))
            {
                ct.ThrowIfCancellationRequested();
                if (summary.InternalDate is not DateTimeOffset received || received < since) continue;
                var subject = summary.Envelope?.Subject ?? "";
                var parts = summary.BodyParts?.ToList() ?? [];
                var attachments = parts.Where(p => IsCandidate(p, subject)).Select(p => new MailAttachmentInfo(
                    Filename(p.FileName), new MailAttachmentRef(account, inbox.UidValidity, summary.UniqueId.Id, p.PartSpecifier))).ToList();
                var hasSupported = parts.Any(p => Extensions.Contains(Path.GetExtension(Filename(p.FileName))));
                var invoiceSubject = subject.Contains("发票", StringComparison.OrdinalIgnoreCase) || subject.Contains("invoice", StringComparison.OrdinalIgnoreCase);
                var message = new InvoiceMailEnvelope(MessageId(account, inbox.UidValidity, summary.UniqueId.Id), subject,
                    summary.Envelope?.From?.ToString() ?? "", received, attachments, invoiceSubject && !hasSupported);
                await receive(message);
            }
        }
        await client.DisconnectAsync(true, ct);
    }

    public static async Task<byte[]> DownloadAttachmentAsync(MailAttachmentRef reference, CancellationToken ct = default)
    {
        var settings = AppSettings.Current;
        var account = settings.MailAddress.Trim().ToLowerInvariant();
        if (!string.Equals(account, reference.Account, StringComparison.OrdinalIgnoreCase) || reference.Uid == 0 ||
            !Regex.IsMatch(reference.PartId, @"^[1-9][0-9]*(?:\.[1-9][0-9]*)*$"))
            throw new InvalidOperationException("附件不属于当前邮箱，或邮件编号已变化，请重新同步。");
        using var client = await ConnectAsync(account, settings.MailPassword, ct);
        var inbox = client.Inbox;
        await inbox.OpenAsync(FolderAccess.ReadOnly, ct);
        if (inbox.UidValidity != reference.UidValidity) throw new InvalidOperationException("邮箱邮件编号已变化，请重新同步后下载。");
        var uid = new UniqueId(reference.Uid);
        var summaries = await inbox.FetchAsync(new[] { uid }, MessageSummaryItems.UniqueId | MessageSummaryItems.BodyStructure, ct);
        var part = summaries.FirstOrDefault()?.BodyParts?.FirstOrDefault(p => p.PartSpecifier == reference.PartId)
            ?? throw new InvalidOperationException("找不到此邮件附件，请在 QQ 邮箱中检查原件。");
        if (part.Octets > MaximumBytes) throw new InvalidOperationException("附件超过 40 MB，请在邮箱中下载后手动导入。");
        var entity = await inbox.GetBodyPartAsync(uid, part, ct, new BoundedProgress());
        if (entity is not MimePart mime || mime.Content == null) throw new InvalidOperationException("附件格式无法解析，请从邮箱手动下载。");
        using var output = new BoundedMemoryStream(MaximumBytes);
        await mime.Content.DecodeToAsync(output, ct);
        var bytes = output.ToArray();
        if (bytes.Length == 0) throw new InvalidOperationException("邮件附件为空。");
        await client.DisconnectAsync(true, ct);
        return bytes;
    }

    internal static string MessageId(string account, uint validity, uint uid) => $"{account}|{validity}|{uid}";
    internal static bool IsCandidate(BodyPartBasic part, string subject)
    {
        var name = Filename(part.FileName);
        var ext = Path.GetExtension(name);
        if (!Extensions.Contains(ext) || !InvoiceRecognition.ShouldList(name, subject)) return false;
        if (!ext.Equals(".pdf", StringComparison.OrdinalIgnoreCase) && !ext.Equals(".zip", StringComparison.OrdinalIgnoreCase))
        {
            if (!part.IsAttachment && !name.Contains("发票", StringComparison.OrdinalIgnoreCase)) return false;
            if (new[] { "logo", "signature", "icon" }.Any(word => name.Contains(word, StringComparison.OrdinalIgnoreCase))) return false;
        }
        return true;
    }
    private static string Filename(string? value) => Path.GetFileName((value ?? "").Replace('\\', '/'));
    private static async Task<ImapClient> ConnectAsync(string address, string password, CancellationToken ct)
    {
        ValidateCredentials(address, password);
        var client = new ImapClient { Timeout = 45_000 };
        try
        {
            await client.ConnectAsync("imap.qq.com", 993, SecureSocketOptions.SslOnConnect, ct);
            await client.AuthenticateAsync(address.Trim().ToLowerInvariant(), password.Trim(), ct);
            return client;
        }
        catch { client.Dispose(); throw; }
    }
    private sealed class BoundedProgress : ITransferProgress
    {
        public void Report(long bytesTransferred) => Report(bytesTransferred, 0);
        public void Report(long bytesTransferred, long totalSize)
        {
            if (bytesTransferred > MaximumBytes || totalSize > MaximumBytes) throw new IOException("附件超过 40 MB，已停止下载。");
        }
    }
    private sealed class BoundedMemoryStream(int limit) : MemoryStream
    {
        public override void Write(byte[] buffer, int offset, int count) { Ensure(count); base.Write(buffer, offset, count); }
        public override void Write(ReadOnlySpan<byte> buffer) { Ensure(buffer.Length); base.Write(buffer); }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
        { Ensure(buffer.Length); return base.WriteAsync(buffer, ct); }
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken ct)
        { Ensure(count); return base.WriteAsync(buffer, offset, count, ct); }
        private void Ensure(int count) { if (Position + count > limit) throw new IOException("附件超过 40 MB，已停止下载。"); }
    }
}
