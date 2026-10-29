using ReimburseApp;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Writer;
using UglyToad.PdfPig.Fonts.Standard14Fonts;

internal static class ManualImportChecks
{
    internal static async Task Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "invoice-manual-parity-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        var builder = new PdfDocumentBuilder();
        var page = builder.AddPage(PageSize.A4);
        page.AddText("Unknown document", 18, new PdfPoint(40, 700), builder.AddStandard14Font(Standard14Font.Helvetica));
        var source = Path.Combine(root, "金额39.00.pdf");
        File.WriteAllBytes(source, builder.Build());
        var repository = new InvoiceRepository("unused", Path.Combine(root, "inbox"));
        await repository.ImportAsync([source]);
        var item = repository.Items.Single();
        Check(item.IsInvoice && item.IsManuallyImported && item.DocumentKind == InvoiceDocumentKind.Invoice, "Manual import bypasses document classification");
        Check(item.Amount == 39m, "Manual metadata keeps filename amount");
        await repository.UpdateAsync(item.Id, "157.00", "手工抬头");
        var cached = repository.SourcePath(item);
        File.Move(cached, cached + ".held");
        item.ManuallyImported = false; item.Source = "邮箱"; item.DocumentKind = InvoiceDocumentKind.Unknown; item.Accepted = false;
        var imported = await repository.ImportAsync([source]);
        Check(imported.SetEquals([item.Id]) && item.IsManuallyImported, "Duplicate pending email is promoted and returned for project assignment");
        Check(repository.Items.Count == 1 && File.Exists(cached), "Repeat import restores missing cache without duplicate");
        Check(item.Amount == 157m && item.BuyerTitle == "手工抬头", "Repeat metadata cannot overwrite user input");
        item.PolicyRevision = -1;
        Check(item.IsInvoice, "Manual trust survives rule version changes");
        var project = Guid.NewGuid();
        await repository.AssignAsync([item.Id], project);
        Check(repository.ForProject(project).Single().IsManuallyImported, "Project retains manual trust");
        var reopened = new InvoiceRepository("unused", Path.Combine(root, "inbox"));
        Check(reopened.Items.Single().IsInvoice && reopened.Items.Single().ManuallyImported == true, "Manual trust persists on disk");
        var legacy = new InvoiceRecord { Source = "手动导入", Accepted = false, PolicyRevision = -1 };
        Check(legacy.IsManuallyImported && legacy.IsInvoice, "Legacy explicit manual source migrates");
        Check(!(legacy with { MailId = "mail" }).IsManuallyImported, "Email archive must not inherit manual trust");
        Console.WriteLine("Manual invoice trust, duplicate recovery and project persistence checks passed; fixtures retained at " + root);
    }
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
