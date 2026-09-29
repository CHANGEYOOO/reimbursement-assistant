using ClosedXML.Excel;
using ClosedXML.Excel.Drawings;
using ImageMagick;

namespace ReimburseApp;

public static class WorkbookExporter
{
    public static void Export(string path, string title, IReadOnlyList<ExpenseRow> rows)
    {
        if (string.IsNullOrWhiteSpace(title)) throw new ArgumentException("请填写报销单标题。", nameof(title));
        if (rows.Count == 0) throw new ArgumentException("请先添加费用记录。", nameof(rows));

        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("报销单");
        sheet.Style.Font.FontName = "Microsoft YaHei";
        sheet.Style.Font.FontSize = 11;
        sheet.Column(1).Width = 8;
        sheet.Column(2).Width = 16;
        sheet.Column(3).Width = 38;
        sheet.Column(4).Width = 35;
        sheet.Column(5).Width = 16;

        sheet.Range("A1:E1").Merge();
        sheet.Cell("A1").Value = title.Trim();
        sheet.Row(1).Height = 38;
        sheet.Cell("A1").Style.Font.Bold = true;
        sheet.Cell("A1").Style.Font.FontSize = 15;
        sheet.Cell("A1").Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        sheet.Cell("A1").Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

        var headings = new[] { "序号", "日期", "名称", "图片", "金额" };
        for (var column = 1; column <= headings.Length; column++)
            sheet.Cell(2, column).Value = headings[column - 1];
        sheet.Row(2).Height = 26;

        for (var index = 0; index < rows.Count; index++)
        {
            var expense = rows[index];
            if (expense.Amount is not > 0 || string.IsNullOrWhiteSpace(expense.Purpose))
                throw new ArgumentException($"第{index + 1}笔费用需要填写正数金额和用途。", nameof(rows));

            var row = index + 3;
            sheet.Row(row).Height = 125;
            sheet.Cell(row, 1).Value = index + 1;
            sheet.Cell(row, 2).Value = expense.Date;
            sheet.Cell(row, 3).Value = expense.Purpose.Trim();
            sheet.Cell(row, 5).Value = expense.Amount.Value;
            sheet.Cell(row, 5).Style.NumberFormat.Format = "0.00";
            sheet.Cell(row, 5).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
            sheet.Cell(row, 3).Style.Alignment.WrapText = true;

            using var image = new MagickImage(expense.ImagePath);
            using var png = new MemoryStream(image.ToByteArray(MagickFormat.Png));
            var scale = Math.Min(1.0, Math.Min(225.0 / image.Width, 155.0 / image.Height));
            sheet.AddPicture(png, XLPictureFormat.Png, $"Image {index + 1}")
                .WithPlacement(XLPicturePlacement.Move)
                .WithSize(Math.Max(1, (int)(image.Width * scale)), Math.Max(1, (int)(image.Height * scale)))
                .MoveTo(sheet.Cell(row, 4), 5, 5);
        }

        var totalRow = rows.Count + 3;
        sheet.Row(totalRow).Height = 28;
        sheet.Cell(totalRow, 1).Value = "合计";
        sheet.Cell(totalRow, 5).FormulaA1 = $"SUM(E3:E{totalRow - 1})";
        sheet.Cell(totalRow, 5).Style.NumberFormat.Format = "0.00";
        sheet.Cell(totalRow, 5).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;

        var table = sheet.Range(2, 1, totalRow, 5);
        table.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        table.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        table.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        sheet.Range(2, 1, totalRow, 2).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        sheet.Range(2, 4, totalRow, 4).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        sheet.Range(2, 1, 2, 5).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        sheet.PageSetup.PaperSize = XLPaperSize.A4Paper;
        sheet.PageSetup.PageOrientation = XLPageOrientation.Portrait;
        sheet.PageSetup.FitToPages(1, 0);
        sheet.PageSetup.CenterHorizontally = true;
        sheet.PageSetup.Margins.Left = 0.3;
        sheet.PageSetup.Margins.Right = 0.3;
        sheet.PageSetup.Margins.Top = 0.4;
        sheet.PageSetup.Margins.Bottom = 0.4;
        sheet.PageSetup.PrintAreas.Add($"A1:E{totalRow}");
        workbook.SaveAs(path);
    }
}
