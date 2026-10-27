using ClosedXML.Excel;
using ClosedXML.Excel.Drawings;
using ReimburseApp;
using System.Globalization;
using System.Text.Json;
using System.Text;

Recognition.SelfCheck();
var fixturePath = Path.Combine(AppContext.BaseDirectory, "OrderRecognitionParity.json");
using (var fixtures = JsonDocument.Parse(File.ReadAllText(fixturePath)))
{
    foreach (var fixture in fixtures.RootElement.EnumerateArray())
    {
        var text = fixture.GetProperty("text").GetString()!;
        var result = Recognition.Suggest(text);
        string? Expected(string key) => fixture.TryGetProperty(key, out var value) ? value.GetString() : null;
        var expectedAmount = Expected("amount") is { } money ? decimal.Parse(money, CultureInfo.InvariantCulture) : (decimal?)null;
        if (result.Amount != expectedAmount || result.Category != Expected("category") || result.Date != Expected("date") || result.Warning != Expected("warning"))
            throw new InvalidOperationException($"Mac/Windows order rule mismatch: {text} => {result}");
    }
    Console.WriteLine($"Mac/Windows same-text parity passed ({fixtures.RootElement.GetArrayLength()} fixtures)");
}

using (var fixtures = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "PositionRecognitionParity.json"))))
{
    foreach (var fixture in fixtures.RootElement.EnumerateArray())
    {
        var lines = fixture.GetProperty("lines").EnumerateArray().Select(line => new PositionedText(line.GetProperty("text").GetString()!, line.GetProperty("x").GetDouble(), line.GetProperty("y").GetDouble())).ToArray();
        var result = Recognition.PositionedAmount(lines);
        var amount = fixture.TryGetProperty("amount", out var money) ? decimal.Parse(money.GetString()!, CultureInfo.InvariantCulture) : (decimal?)null;
        var warning = fixture.TryGetProperty("warning", out var note) ? note.GetString() : null;
        var candidates = fixture.GetProperty("candidates").EnumerateArray().Select(value => decimal.Parse(value.GetString()!, CultureInfo.InvariantCulture));
        if (result?.Amount != amount || result?.Warning != warning || !Recognition.Candidates(lines).Select(candidate => candidate.Amount).SequenceEqual(candidates))
            throw new InvalidOperationException("Mac/Windows positioned/candidate mismatch: " + fixture.GetProperty("name").GetString());
    }
    Console.WriteLine($"Mac/Windows layout and candidate parity passed ({fixtures.RootElement.GetArrayLength()} fixtures)");
}

byte[] Response(string content) => JsonSerializer.SerializeToUtf8Bytes(new { choices = new[] { new { finish_reason = "stop", message = new { content } } } });
SemanticClassification Decode(string source, string payment = "null", string date = "null") => SemanticClassifier.DecodeResponse(Response("{\"category\":\"餐食\",\"certainty\":\"high\",\"reason\":\"商品是可食用食品\",\"payment\":" + payment + ",\"transaction_date\":" + date + "}"), source, new DateTime(2026, 10, 27));
void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
var negative = Decode("汉堡\n支付成功\n-34.22", "{\"amount\":\"34.22\",\"certainty\":\"high\",\"reason\":\"明确扣款\",\"candidates\":[\"34.22\"]}");
Check(negative.Payment?.IsCertain == true && negative.Payment.Amount == 34.22m, "Negative debit must be a positive evidenced expense");
var invented = Decode("实付¥34.22\n订单号12345678\n日期2026-10-27", "{\"amount\":\"99.00\",\"certainty\":\"high\",\"reason\":\"无依据\",\"candidates\":[\"12345678\",\"99.00\"]}");
Check(invented.Payment?.IsCertain == false && invented.Payment.Amount == null && invented.Payment.Candidates.SequenceEqual(new[] {34.22m}), "AI must not invent money or use identifiers");
var refunded = Decode("退款成功\n-34.22", "{\"amount\":\"34.22\",\"certainty\":\"high\",\"reason\":\"退款\",\"candidates\":[\"34.22\"]}");
Check(refunded.Payment?.Amount == null && refunded.Payment.Candidates.Count == 0, "Refund must not become a payment");
var approximate = Decode("下单快照\n10月16日", date: "{\"date\":null,\"certainty\":\"uncertain\",\"reason\":\"参考下单日期\",\"candidates\":[\"2026-10-16\"]}");
Check(approximate.TransactionDate?.Candidates.FirstOrDefault() == "2026-10-16" && approximate.TransactionDate.Reason.Contains("当前年份2026"), "Month/day gets current year and remains a valid approximate candidate");
var explicitYear = Decode("支付日期2024年10月16日", date: "{\"date\":\"2026-10-16\",\"certainty\":\"high\",\"reason\":\"日期\",\"candidates\":[]}");
Check(explicitYear.TransactionDate?.Date == null && explicitYear.TransactionDate.Candidates.Single() == "2024-10-16", "Explicit year cannot be replaced");
var invalidDate = Decode("支付日期2026-02-30\n金额¥10.16", date: "{\"date\":\"2026-10-16\",\"certainty\":\"high\",\"reason\":\"伪造日期\",\"candidates\":[\"2026-02-30\"]}");
Check(invalidDate.TransactionDate?.Candidates.Count == 0, "Invalid full date and decimal price must not become dates");
Check(SemanticClassifier.MonetaryEvidence("付款时间\n10.16\n订单号12345678\n电话13812345678").Count == 0, "Temporal/identifier tokens cannot become money");
foreach (var endpoint in new[] { "http://example.com/chat", "https://user:pass@example.com/chat", "https://example.com/chat?key=x", "https://example.com/chat#key" })
{
    var rejected = false;
    try { SemanticClassifier.ValidateConfiguration(endpoint, "model", "test"); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected, "Invalid API endpoint must be rejected");
}
var dateOnlyMoney = Decode("支付时间\n10.16", "{\"amount\":\"10.16\",\"certainty\":\"high\",\"reason\":\"日期不是金额\",\"candidates\":[]}");
Check(dateOnlyMoney.Payment?.IsCertain == false && dateOnlyMoney.Payment.Amount == null, "A dotted date under a time label cannot become money");
var invalidPayload = false;
try { SemanticClassifier.DecodeResponse(Response("{\"category\":\"不存在\",\"certainty\":\"high\",\"reason\":\"伪造分类\"}"), "内容", DateTime.Today); }
catch (InvalidOperationException) { invalidPayload = true; }
Check(invalidPayload, "Unknown category must be rejected");
var unresolved = new ExpenseRow { RecognizedText = "汉堡\n商家合计20.00", Category = "餐食", Purpose = "餐食费用", Amount = 20, Date = "2026-10-27", Warning = "仅识别到订单合计，未见实付标识，请人工核对" };
Check(SemanticClassifier.NeedsAssistance(unresolved), "Unconfirmed total-only amount must receive automatic assistance");
unresolved.Edited.Add("amount");
Check(!SemanticClassifier.NeedsAssistance(unresolved), "Manual money edit must prevent automatic overwrite");
var model = new ExpenseRow { Amount = 1, Category = "餐食", Purpose = "餐食费用", Date = "0001-01-01" };
Check(model.Issues.Count > 0, "Manual date must respect Mac minimum year1900");
model.Date = "2100-01-01";
Check(model.Issues.Count > 0, "Manual date must respect Mac maximum year2099");
model.Date = "2026-10-27"; model.Confirmed = true; model.Amount = null;
Check(model.Issues.Count > 0, "Manual confirmation cannot bypass missing required amount");
model.Amount = 1; model.Date = "";
Check(model.Issues.Count > 0, "Manual confirmation cannot bypass missing required date");
model.Date = "2026-10-27"; model.Purpose = "";
Check(model.Issues.Count > 0, "Manual confirmation cannot bypass missing required purpose");
Console.WriteLine("AI evidence, current-year dates, refund guards, manual-edit gates and endpoint checks passed (offline)");
if (args.Length > 1)
{
    foreach (var path in args.Skip(1))
    {
        var result = path.EndsWith(".txt", StringComparison.OrdinalIgnoreCase)
            ? Recognition.Suggest(File.ReadAllText(path))
            : Recognition.FromPng(File.ReadAllBytes(path), args[0]);
        Console.WriteLine($"{Path.GetFileName(path)}: {result.Amount?.ToString() ?? "待选择"} | {string.Join(", ", result.AmountCandidates.Select(item => item.Amount))} | {result.Warning}");
    }
    return;
}
using var workbook = new XLWorkbook();
var sheet = workbook.AddWorksheet("报销单");
using var png = new MemoryStream(Convert.FromBase64String(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/c1sAAAAASUVORK5CYII="));
sheet.AddPicture(png, XLPictureFormat.Png, "Image 1")
    .WithPlacement(XLPicturePlacement.Move)
    .WithSize(100, 100)
    .MoveTo(sheet.Cell(3, 4), 5, 5);
using var output = new MemoryStream();
workbook.SaveAs(output);
Console.WriteLine("识别规则及 Excel 图片导出自检通过");
