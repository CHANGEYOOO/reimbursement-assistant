using ReimburseApp;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Writer;
using UglyToad.PdfPig.Fonts.Standard14Fonts;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var ordinary = "电子发票（普通发票）\n发票号码：12345678901234567890\n开票日期：2026年10月27日\n购买方信息\n销售方信息\n价税合计（大写）（小写）\n¥127.46";
Check(InvoiceRecognition.Classify(ordinary).accepted, "Ordinary invoice accepted");
foreach (var title in new[] { "电子发票（航空运输电子客票行程单）", "电子发票（铁路电子客票）", "费用报销单", "发票清单" })
    Check(!InvoiceRecognition.Classify(ordinary.Replace("电子发票（普通发票）", title)).accepted, "Unsupported type: " + title);
Check(!InvoiceRecognition.Classify(ordinary.Replace("销售方信息", "")).accepted, "Incomplete fields fail closed");
Check(InvoiceRecognition.Classify(ordinary.Replace("电子发票（普通发票）", "增值税电子普通发票")).accepted, "Legacy ordinary title");
Check(InvoiceRecognition.ShouldList("滴滴行程单.pdf", "电子发票"), "Filename selects candidates; content decides classification");
Check(InvoiceRecognition.ClassifyKind("滴滴行程单\n发票号码12345678901234567890\n税额1.00").kind == InvoiceDocumentKind.NonInvoice, "Itinerary distinguished by content");
Check(InvoiceRecognition.Classify(ordinary.Replace("普通发票", "专用发票")).accepted, "Digital special invoice supported");
Check(InvoiceRecognition.Classify(ordinary.Replace("电子发票（普通发票）", "增值税电子专用发票")).accepted, "Legacy special invoice supported");
Check(InvoiceRecognition.ClassifyKind("发票号码12345678901234567890 税额1.00").kind == InvoiceDocumentKind.Unknown, "Loose labels cannot admit invoice");
var pendingReading = new InvoiceReading(false, "local uncertain", null, "", "", "");
Check(InvoiceAIFallback.Apply(pendingReading, new("digital_general", true, "high", "完整票面", "")).Accepted, "Definitive AI does not require local verification");
Check(InvoiceAIFallback.Apply(pendingReading, new("hotel_statement", false, "high", "酒店住宿明细", "")).Kind == InvoiceDocumentKind.NonInvoice, "AI noninvoice accepted");
Check(InvoiceAIFallback.Apply(pendingReading, new("digital_general", false, "high", "矛盾", "")).Kind == InvoiceDocumentKind.Unknown, "Contradictory AI pending");
Check(InvoiceAIFallback.Apply(pendingReading, new("digital_general", true, "uncertain", "模糊", "不确定")).Kind == InvoiceDocumentKind.Unknown, "Uncertain AI pending");
Check(InvoiceRecognition.ShouldList("发票及行程单.zip", ""), "Mixed bundle inspected entry by entry");
Check(InvoiceRecognition.AmountInFilename("2026-10-27_发票_127.46.pdf") == 127.46m, "Date excluded from filename money");
Check(InvoiceRecognition.AmountInFilename("金额89元_原价199.00.pdf") == 89m, "Explicit filename label takes priority");
Check(InvoiceRecognition.AmountInFilename("89.00_199.00.pdf") == null, "Ambiguous filename stays unresolved");
Check(InvoiceRecognition.TotalInText("金额123.75 税额3.71\n价税合计（大写）（小写）¥127.46") == 127.46m, "Tax-inclusive total");
Check(InvoiceRecognition.TotalInText("价税合计（小写）-127.46") == null, "Negative red invoice total not reimbursed");
Check(InvoiceRecognition.TotalInText("价税合计（小写）127.46 128.00") == null, "Conflicting totals unresolved");
var root = Path.Combine(Path.GetTempPath(), "reimbursement-invoice-check-" + Guid.NewGuid());
Directory.CreateDirectory(root); AppPaths.SetRoot(root);
var repository = new InvoiceRepository("unused", AppPaths.Invoices);
var reference = new MailAttachmentRef("one@qq.com", 4, 10, "1");
var message = new InvoiceMailEnvelope("one", "发票", "sender", DateTimeOffset.Now, [new("发票.pdf", reference)], false);
await repository.RegisterMailAsync(message, false);
await repository.RegisterMailAsync(message, true);
Check(repository.Items.Count == 1 && !repository.Items[0].AutoDownloadPending, "Historic metadata never promoted by repeat sync");
await repository.RegisterMailAsync(message with { Id = "two", Attachments = [new("发票.pdf", reference with { Uid = 11 })] }, true);
var skipped = await repository.DownloadPendingAsync("two@qq.com", () => true);
Check(skipped == (0, 0) && repository.Items[1].AutoDownloadPending, "Account isolation");
var stopped = await repository.DownloadPendingAsync("one@qq.com", () => false);
Check(stopped == (0, 0) && repository.Items[1].AutoDownloadPending, "Config cancellation gate");
var failed = await repository.DownloadPendingAsync("one@qq.com", () => true);
Check(failed == (0, 1) && repository.Items[1].AutoDownloadPending, "Failure remains queued");
var reopened = new InvoiceRepository("unused", AppPaths.Invoices);
Check(reopened.Items[1].AutoDownloadPending, "Queue survives restart");
var reportBuilder = new PdfDocumentBuilder();
var reportPage = reportBuilder.AddPage(PageSize.A4);
reportPage.AddText("Expense report", 24, new PdfPoint(40, 700), reportBuilder.AddStandard14Font(Standard14Font.Helvetica));
var report = Path.Combine(root, "金额39.00.pdf");
File.WriteAllBytes(report, reportBuilder.Build());
var excludedRepository = new InvoiceRepository("unused", Path.Combine(root, "excluded"));
await excludedRepository.ImportAsync([report]);
Check(excludedRepository.Items[0].IsInvoice, "Manual import trusted independent of document screening");
await excludedRepository.RegisterMailAsync(message with { Id = "report", Attachments = [new("发票.pdf", reference with { Uid = 20 })] }, true);
MailService.Downloader = _ => Task.FromResult(File.ReadAllBytes(report));
var excluded = await excludedRepository.DownloadPendingAsync("one@qq.com", () => true);
Check(excluded == (0, 0) && !excludedRepository.Items[1].AutoDownloadPending && !excludedRepository.Items[1].IsInvoice, "Excluded report finishes queue without invoice notification");
if (args.Length > 0)
{
    var reading = InvoiceRecognition.Read(args[0], args.Length > 1 ? args[1] : "unused");
    Check(reading.Accepted, "User invoice accepted");
    Check(reading.Amount == 127.46m, "User total127.46, not pretax or tax");
    Check(reading.Buyer.Length > 0 && reading.Seller.Length > 0, "User buyer/seller identified");
    using (var original = PdfDocument.Open(args[0]))
    {
        var mixedBuilder = new PdfDocumentBuilder();
        mixedBuilder.AddPage(original, 1);
        var second = mixedBuilder.AddPage(PageSize.A4);
        second.AddText("Expense report", 24, new PdfPoint(40, 700), mixedBuilder.AddStandard14Font(Standard14Font.Helvetica));
        var mixed = Path.Combine(root, "mixed-invoice.pdf");
        File.WriteAllBytes(mixed, mixedBuilder.Build());
        Check(!InvoiceRecognition.Read(mixed, "unused").Accepted, "Invoice first page cannot admit report second page");
    }
    MailService.Downloader = _ => Task.FromResult(File.ReadAllBytes(args[0]));
    var result = await reopened.DownloadPendingAsync("one@qq.com", () => true);
    Check(result == (1, 0) && !reopened.Items[1].AutoDownloadPending, "Successful download/classification finishes queue");
    var id = reopened.Items[1].Id;
    var project = Guid.NewGuid();
    await reopened.AssignAsync([id], project);
    Check(reopened.ForProject(project).Count == 1 && File.Exists(reopened.ProjectPath(reopened.Items[1])), "Project receives independent copy");
    var exported = await reopened.ExportAsync(project, root);
    Check(Directory.GetFiles(exported).Length == 1 && Path.GetFileName(exported).EndsWith("-127.46"), "Folder date-total export");
    await reopened.UpdateAsync(id, "128.00", "", projectOnly: true);
    Check(reopened.Items[1].Amount == 127.46m && reopened.ForProject(project)[0].Amount == 128m, "Project money edits preserve inbox metadata");
    Console.WriteLine("User sample: " + reading.Amount + " buyer=" + reading.Buyer + " seller=" + reading.Seller);
}
StructuredInvoiceChecks.Run();
await ManualImportChecks.Run();
await InvoiceAIChecks.Run();
Console.WriteLine("Invoice rule/storage checks passed; fixtures retained at " + root);

namespace ReimburseApp
{
    public static class AppPaths
    {
        public static string Root { get; private set; } = Path.Combine(Path.GetTempPath(), "unused-invoice-root");
        public static string Projects => Path.Combine(Root, "projects");
        public static string Invoices => Path.Combine(Root, "inbox");
        public static void SetRoot(string value) { Root = value; Directory.CreateDirectory(Projects); }
    }
    public sealed class AppSettings
    {
        public static AppSettings Current { get; } = new();
        public double CacheLimitMb { get; set; } = 200;
        public bool AiEnabled { get; set; }
        public bool InvoiceFallbackEnabled { get; set; }
        public string AiEndpoint { get; set; } = "https://example.invalid/chat/completions";
        public string AiModel { get; set; } = "offline";
        public string ApiKey { get; set; } = "offline";
        public AppSettings Copy() => (AppSettings)MemberwiseClone();
        public static void ValidateAi(string endpoint, string model, string key) { }
        internal static void WriteJson<T>(string path, T value) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(value)); }
    }
    public sealed record MailAttachmentRef(string Account, uint UidValidity, uint Uid, string PartId);
    public sealed record MailAttachmentInfo(string Filename, MailAttachmentRef Reference);
    public sealed record InvoiceMailEnvelope(string Id, string Subject, string Sender, DateTimeOffset ReceivedAt, IReadOnlyList<MailAttachmentInfo> Attachments, bool HasDownloadLink);
    public static class MailService
    {
        public static Func<MailAttachmentRef, Task<byte[]>> Downloader { get; set; } = _ => throw new IOException("Offline deliberate download failure");
        public static Task<byte[]> DownloadAttachmentAsync(MailAttachmentRef reference, CancellationToken ct = default) => Downloader(reference);
    }
}
