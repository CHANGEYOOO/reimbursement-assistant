using System.Text;
using System.Text.Json;
using ReimburseApp;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Writer;
using UglyToad.PdfPig.Fonts.Standard14Fonts;

internal static class InvoiceAIChecks
{
    internal static async Task Run()
    {
        static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
        var root = Path.Combine(Path.GetTempPath(), "invoice-ai-parity-" + Guid.NewGuid()); Directory.CreateDirectory(root); AppPaths.SetRoot(root);
        var source = Path.Combine(root, "unknown.pdf"); var builder = new PdfDocumentBuilder(); var page = builder.AddPage(PageSize.A4); page.AddText("Invoice document", 18, new PdfPoint(40, 700), builder.AddStandard14Font(Standard14Font.Helvetica)); File.WriteAllBytes(source, builder.Build());
        var pending = new InvoiceReading(false, "本地未知", 39, "", "", "") { Text = "发票票面本地文字" };
        var settings = AppSettings.Current;
        settings.AiEnabled = true; settings.InvoiceFallbackEnabled = false; settings.ApiKey = "offline-key-never-send"; settings.AiModel = "vision-offline";
        var calls = 0; var sender = InvoiceAIFallback.Sender;
        InvoiceAIFallback.Sender = async (request, token) =>
        {
            Interlocked.Increment(ref calls);
            Check(request.RequestUri?.Host == "example.invalid", "Mock endpoint only");
            var payload = await request.Content!.ReadAsStringAsync(token);
            Check(payload.Contains("data:image/jpeg;base64,") && payload.Contains("image_url"), "Text and rendered pages supplied together");
            Check(!payload.Contains("offline-key-never-send"), "Key stays in authorization header");
            await Task.Delay(20, token);
            return Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { choices = new[] { new { finish_reason = "stop", message = new { content = JsonSerializer.Serialize(new InvoiceAIReport("digital_general", true, "high", "完整正式电子发票版式", "")) } } } }));
        };
        try
        {
            var disabled = await InvoiceAIFallback.ReviewAsync(source, pending, settings.Copy()); Check(!disabled.Accepted && calls == 0, "No upload before invoice authorization");
            settings.InvoiceFallbackEnabled = true;
            var local = pending with { Accepted = true, Kind = InvoiceDocumentKind.Invoice };
            Check((await InvoiceAIFallback.ReviewAsync(source, local, settings.Copy())).Accepted && calls == 0, "Local definite invoice no AI");
            var nonInvoice = pending with { Kind = InvoiceDocumentKind.NonInvoice };
            Check((await InvoiceAIFallback.ReviewAsync(source, nonInvoice, settings.Copy())).Kind == InvoiceDocumentKind.NonInvoice && calls == 0, "Local noninvoice no AI");
            var results = await Task.WhenAll(InvoiceAIFallback.ReviewAsync(source, pending, settings.Copy()), InvoiceAIFallback.ReviewAsync(source, pending, settings.Copy()));
            Check(results.All(r => r.Accepted) && calls == 1, "Concurrent same-file single API call");
            var renamed = Path.Combine(root, "renamed.pdf"); File.Copy(source, renamed);
            Check((await InvoiceAIFallback.ReviewAsync(renamed, pending, settings.Copy())).Accepted && calls == 1, "Rename uses content cache");
            var cache = File.ReadAllText(Path.Combine(root, "invoice-ai-cache.json"));
            Check(!cache.Contains("offline-key-never-send") && !cache.Contains("发票票面本地文字") && !cache.Contains("base64"), "Cache excludes keys, raw document text, page images");
            settings.AiModel = "vision-failure";
            InvoiceAIFallback.Sender = (_, _) => { calls++; throw new HttpRequestException("offline simulated failure"); };
            Check(!(await InvoiceAIFallback.ReviewAsync(source, pending, settings.Copy())).Accepted && calls == 2, "Failure stays pending");
            Check(!(await InvoiceAIFallback.ReviewAsync(renamed, pending, settings.Copy())).Accepted && calls == 2, "Failure persisted; no repeated paid attempt");
            settings.InvoiceFallbackEnabled = false;
            Check(!(await InvoiceAIFallback.ReviewAsync(source, pending, settings.Copy())).Accepted && calls == 2, "Revoked consent never reuses positive cache or sends");
            Console.WriteLine("Invoice AI mock request/cache/privacy checks passed; fixtures retained at " + root);
        }
        finally { InvoiceAIFallback.Sender = sender; settings.AiEnabled = false; settings.InvoiceFallbackEnabled = false; }
    }
}
