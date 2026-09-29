using ClosedXML.Excel;
using ClosedXML.Excel.Drawings;
using ReimburseApp;

Recognition.SelfCheck();
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
