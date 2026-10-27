using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using ImageMagick;
using PDFtoImage;
using SkiaSharp;
using Tesseract;
using UglyToad.PdfPig;

namespace ReimburseApp;

public sealed record InvoiceReading(bool Accepted, string Reason, decimal? Amount, string Buyer, string Seller, string Item);

public static class InvoiceRecognition
{
    public const int PolicyRevision = 2;
    private static readonly string[] Supporting = ["电子客票", "行程单", "行程明细", "行程记录", "出行记录", "行程确认单", "报销单", "报销汇总", "报销明细", "费用明细", "费用清单", "发票清单", "发票汇总", "订单明细", "订单详情", "对账单", "付款凭证", "支付凭证", "itinerary", "expensereport", "invoicelist", "invoicesummary", "paymentreceipt"];
    private const string MoneyPattern = @"(?<![\d.])(?:[-−–]\s*[¥￥]?|[¥￥]\s*[-−–]?)?\s*(?:\d{1,3}(?:,\d{3})+|\d(?:[ \t]*\d){0,8})(?:\s*\.\s*\d(?:[ \t]*\d)?)?(?![\d.%])";
    private sealed record Glyph(string Text, double X, double Y, double W, double H)
    {
        public double Right => X + W;
        public double Top => Y + H;
        public double MidX => X + W / 2;
        public double MidY => Y + H / 2;
    }
    private sealed record PageReading(string Text, List<Glyph> Glyphs);

    public static bool ShouldList(string filename, string subject)
    {
        var name = Compact(Path.GetFileName(filename));
        var invoice = name.Contains("发票") || name.Contains("invoice") || name.StartsWith("dzfp");
        if (Path.GetExtension(name) == ".zip" && invoice) return true;
        return !Supporting.Any(name.Contains) && (invoice || Compact(subject).Contains("发票") || Compact(subject).Contains("invoice"));
    }

    public static (bool accepted, string reason) Classify(string text)
    {
        var normalized = text.Normalize(NormalizationForm.FormKC);
        var lines = normalized.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Select(Compact).Where(x => x.Length > 0).Take(12).ToList();
        var source = Compact(normalized);
        if (source.Length == 0) return (false, "尚未取得可识别的票面内容，已排除。");
        var title = lines.FindIndex(InvoiceTitle);
        var supporting = lines.FindIndex(line => Supporting.Any(line.Contains));
        if (supporting >= 0 && (title < 0 || supporting <= title)) return (false, "票面标题为行程、报销或明细材料，不作为发票计入。");
        var number = (source.Contains("发票号码") || source.Contains("发票号")) && Regex.IsMatch(normalized, @"(?<![0-9])[0-9]{8,20}(?![0-9])");
        var date = source.Contains("开票日期") && Regex.IsMatch(source, @"(?:19|20)[0-9]{2}[年./-](?:0?[1-9]|1[0-2])[月./-](?:0?[1-9]|[12][0-9]|3[01])");
        return title >= 0 && number && date && source.Contains("价税合计") && source.Contains("购买方") && source.Contains("销售方")
            ? (true, "已识别为电子普通发票，关键票面字段齐全。")
            : (false, "未能自动确认是字段齐全的电子普通发票，已排除。");
    }

    private static bool InvoiceTitle(string line) => !new[] { "说明", "申请", "清单", "汇总", "报销单", "报销明细", "操作指南" }.Any(line.Contains)
        && Regex.IsMatch(line, @"^(?:[\u3400-\u9fff]{0,12})?(?:增值税电子普通发票|电子发票[（(]?普通发票[）)]?)");
    private static string Compact(string text) => string.Concat(text.Normalize(NormalizationForm.FormKC).ToLowerInvariant().Where(c => !char.IsWhiteSpace(c)));

    public static decimal? AmountInFilename(string filename)
    {
        var name = Path.GetFileNameWithoutExtension(filename).Normalize(NormalizationForm.FormKC);
        name = Regex.Replace(name, @"(?<!\d)(?:19|20)\d{2}[-._年]\d{1,2}[-._月]\d{1,2}日?(?!\d)|(?<!\d)(?:19|20)\d{6}(?!\d)", " ");
        var patterns = new[] {
            @"(?:价税合计|发票金额|总金额|金额|[¥￥])\s*[:：]?\s*[¥￥]?\s*(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)",
            @"(?<![\d.])(\d{1,9}(?:\.\d{1,2})?)\s*元",
            @"(?<![\d.])(\d{1,9}\.\d{2})(?![\d.])"
        };
        foreach (var pattern in patterns)
        {
            var values = Regex.Matches(name, pattern).Cast<Match>().Select(m => decimal.TryParse(m.Groups[1].Value.Replace(",", ""), NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var v) ? v : 0).Where(v => v > 0).Distinct().ToList();
            if (values.Count > 1) return null;
            if (values.Count == 1) return values[0];
        }
        return null;
    }

    public static InvoiceReading Read(string path, string tessdataDirectory)
    {
        var pages = new List<PageReading>();
        if (Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase))
        {
            using var document = PdfDocument.Open(path);
            if (document.NumberOfPages == 0) return new(false, "PDF 没有可识别的票面。", null, "", "", "");
            byte[]? bytes = null;
            for (var i = 1; i <= document.NumberOfPages; i++)
            {
                var page = document.GetPage(i);
                var glyphs = page.Letters.Where(l => !string.IsNullOrWhiteSpace(l.Value)).Select(l => new Glyph(l.Value.Normalize(NormalizationForm.FormKC), l.BoundingBox.Left, l.BoundingBox.Bottom, l.BoundingBox.Width, l.BoundingBox.Height)).ToList();
                var native = new PageReading(Lines(glyphs) + "\n" + page.Text, glyphs);
                if (!Classify(native.Text).accepted && !HasSupportingTitle(native.Text))
                {
                    bytes ??= File.ReadAllBytes(path);
                    using var stream = new MemoryStream(bytes, false);
                    using var bitmap = Conversion.ToImage(stream, page: i - 1, options: new RenderOptions(Dpi: 180));
                    using var encoded = bitmap.Encode(SKEncodedImageFormat.Png, 100);
                    var scanned = ReadImage(encoded.ToArray(), tessdataDirectory);
                    if (Classify(scanned.Text).accepted || glyphs.Count == 0) native = scanned;
                }
                pages.Add(native);
            }
        }
        else
        {
            using var image = new MagickImage(path);
            image.Format = MagickFormat.Png;
            pages.Add(ReadImage(image.ToByteArray(), tessdataDirectory));
        }
        foreach (var page in pages)
        {
            var classification = Classify(page.Text);
            if (!classification.accepted) return new(false, classification.reason, null, "", "", "");
        }
        var text = string.Join("\n", pages.Select(p => p.Text));
        var totals = pages.SelectMany(p => SpatialAmounts(p.Glyphs)).ToList();
        var amount = AmountInFilename(path) ?? (totals.Count > 0 ? UniquePositive(totals) : TotalInText(text));
        var first = pages.Select(p => Parties(p.Glyphs)).FirstOrDefault(p => p.buyer.Length > 0 || p.seller.Length > 0);
        var plain = PartiesInText(text);
        var item = text.Split('\n').FirstOrDefault(l => l.Contains('*') || l.Contains('＊')) ?? "";
        return new(true, "所有页面均通过电子普通发票检查。", amount, string.IsNullOrEmpty(first.buyer) ? plain.buyer : first.buyer, string.IsNullOrEmpty(first.seller) ? plain.seller : first.seller, item);
    }

    public static byte[] PreviewPng(string path, int pageIndex = 0)
    {
        if (Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase))
        {
            using var stream = File.OpenRead(path);
            using var bitmap = Conversion.ToImage(stream, page: pageIndex, options: new RenderOptions(Dpi: 150));
            using var image = bitmap.Encode(SKEncodedImageFormat.Png, 100);
            return image.ToArray();
        }
        using var raster = new MagickImage(path);
        raster.Format = MagickFormat.Png;
        return raster.ToByteArray();
    }

    private static bool HasSupportingTitle(string text) => text.Split('\n').Take(12).Any(line => Supporting.Any(Compact(line).Contains));

    private static PageReading ReadImage(byte[] png, string tessdataDirectory)
    {
        using var engine = new TesseractEngine(tessdataDirectory, "chi_sim+eng", EngineMode.Default);
        using var image = Pix.LoadFromMemory(png);
        using var page = engine.Process(image);
        using var iterator = page.GetIterator();
        var glyphs = new List<Glyph>();
        iterator.Begin();
        do
        {
            var value = iterator.GetText(PageIteratorLevel.Symbol);
            if (!string.IsNullOrWhiteSpace(value) && iterator.TryGetBoundingBox(PageIteratorLevel.Symbol, out var box))
                glyphs.Add(new(value.Normalize(NormalizationForm.FormKC), box.X1, image.Height - box.Y2, box.Width, box.Height));
        } while (iterator.Next(PageIteratorLevel.Symbol));
        return new(Lines(glyphs), glyphs);
    }

    private static List<List<Glyph>> Rows(List<Glyph> glyphs)
    {
        var rows = new List<List<Glyph>>();
        foreach (var piece in glyphs.OrderByDescending(g => g.MidY))
        {
            var row = rows.FirstOrDefault(r => Math.Abs(r[0].MidY - piece.MidY) < Math.Min(r[0].H, piece.H) * .45);
            if (row == null) rows.Add([piece]); else row.Add(piece);
        }
        return rows.Select(row => row.OrderBy(g => g.X).ToList()).ToList();
    }

    private static string Lines(List<Glyph> glyphs) => string.Join("\n", Rows(glyphs).Select(row => string.Concat(row.Select(g => g.Text))));
    private static List<decimal> SpatialAmounts(List<Glyph> glyphs)
    {
        var values = new List<decimal>();
        foreach (var row in Rows(glyphs))
        {
            var joined = string.Concat(row.Select(g => g.Text));
            var labels = Regex.Matches(joined, @"小\s*写|价\s*税\s*合\s*计|合\s*计\s*金\s*额|发\s*票\s*金\s*额").Cast<Match>().ToList();
            var label = labels.FirstOrDefault(m => Compact(m.Value) == "小写") ?? labels.FirstOrDefault();
            if (label != null) values.AddRange(Amounts(joined[(label.Index + label.Length)..]));
        }
        return values;
    }

    public static decimal? TotalInText(string text)
    {
        var source = text.Normalize(NormalizationForm.FormKC);
        foreach (var label in new[] { "价税合计", "合计金额", "发票金额", "小写" })
            source = Regex.Replace(source, string.Join(@"\s*", label.ToCharArray()), label);
        var lines = source.Split('\n');
        var values = new List<decimal>();
        for (var i = 0; i < lines.Length; i++)
        {
            var label = new[] { "价税合计", "合计金额", "发票金额" }.FirstOrDefault(lines[i].Contains);
            if (label == null) continue;
            var section = lines.Skip(i).Take(8).ToList();
            var small = section.FindIndex(l => l.Contains("小写"));
            if (small >= 0)
            {
                var found = Amounts(section[small][(section[small].IndexOf("小写", StringComparison.Ordinal) + 2)..]);
                if (found.Count == 0 && small + 1 < section.Count) found = Amounts(section[small + 1]);
                values.AddRange(found);
            }
            else values.AddRange(Amounts(lines[i][(lines[i].IndexOf(label, StringComparison.Ordinal) + label.Length)..]));
        }
        return UniquePositive(values);
    }
    private static List<decimal> Amounts(string source) => Regex.Matches(source, MoneyPattern).Cast<Match>().Select(m => Regex.Replace(m.Value.Replace("¥", "").Replace("￥", "").Replace(",", "").Replace('−', '-').Replace('–', '-'), @"\s", "")).Select(t => decimal.TryParse(t, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var value) ? (decimal?)value : null).Where(v => v.HasValue).Select(v => v!.Value).ToList();
    private static decimal? UniquePositive(IEnumerable<decimal> amounts)
    {
        var values = amounts.Distinct().ToList();
        return values.Count == 1 && values[0] > 0 ? values[0] : null;
    }

    private static (string buyer, string seller) Parties(List<Glyph> glyphs)
    {
        Glyph? Role(string word)
        {
            foreach (var vertical in new[] { true, false })
                foreach (var first in glyphs.Where(g => g.Text == word[..1]))
                {
                    var chain = new List<Glyph> { first };
                    foreach (var c in word[1..])
                    {
                        var previous = chain[^1];
                        var next = glyphs.Where(g => g.Text == c.ToString() && (vertical
                            ? Math.Abs(g.MidX - previous.MidX) <= Math.Max(previous.W, g.W) * .6 && g.MidY < previous.MidY && previous.MidY - g.MidY < Math.Max(previous.H, g.H) * 2.5
                            : Math.Abs(g.MidY - previous.MidY) <= Math.Max(previous.H, g.H) * .6 && g.MidX > previous.MidX && g.MidX - previous.MidX < Math.Max(previous.W, g.W) * 2.5)).OrderBy(g => Math.Pow(g.MidX - previous.MidX, 2) + Math.Pow(g.MidY - previous.MidY, 2)).FirstOrDefault();
                        if (next == null) break;
                        chain.Add(next);
                    }
                    if (chain.Count == word.Length) return new(word, chain.Min(g => g.X), chain.Min(g => g.Y), chain.Max(g => g.Right) - chain.Min(g => g.X), chain.Max(g => g.Top) - chain.Min(g => g.Y));
                }
            return null;
        }
        var buyer = Role("购买方") ?? Role("付款方");
        var seller = Role("销售方") ?? Role("收款方");
        var roles = new[] { buyer, seller }.Where(g => g != null).Cast<Glyph>().ToList();
        var labels = new List<Glyph>();
        foreach (var row in Rows(glyphs))
            for (var i = 0; i < row.Count - 1; i++)
                if (row[i].Text == "名" && row[i + 1].Text == "称")
                {
                    var prefix = string.Concat(row.Take(i).TakeLast(8).Select(g => g.Text));
                    if (!new[] { "项目", "商品", "货物", "服务" }.Any(prefix.EndsWith))
                        labels.Add(new("名称", row[i].X, Math.Min(row[i].Y, row[i + 1].Y), row[i + 1].Right - row[i].X, Math.Max(row[i].H, row[i + 1].H)));
                }
        string Name(Glyph? anchor)
        {
            if (anchor == null) return "";
            var rightEdge = roles.Where(g => g.X > anchor.Right + 8).Select(g => g.X).DefaultIfEmpty(double.MaxValue).Min();
            var horizontal = anchor.W > anchor.H;
            var label = labels.Where(l => l.X >= (horizontal ? anchor.X : anchor.Right) - 2 && l.Right < rightEdge && l.MidY >= anchor.Y - l.H * 3 && l.MidY <= anchor.Top + l.H).OrderBy(l => horizontal ? Math.Abs(l.X - anchor.X) + Math.Abs(l.MidY - anchor.Y) * 2 : l.X - anchor.Right + Math.Abs(l.MidY - anchor.Top) * 2).FirstOrDefault();
            if (label == null) return "";
            var next = labels.Where(l => l.X > label.Right && Math.Abs(l.MidY - label.MidY) < Math.Max(l.H, label.H)).Select(l => l.X).DefaultIfEmpty(rightEdge).Min();
            var row = glyphs.Where(g => g.MidX > label.Right && g.MidX < Math.Min(rightEdge, next) - 1 && Math.Abs(g.MidY - label.MidY) < Math.Max(g.H, label.H) * .55).OrderBy(g => g.MidX).ToList();
            var connected = new List<Glyph>();
            foreach (var g in row)
            {
                if (connected.Count > 0 && g.X - connected[^1].Right > Math.Max(connected[^1].H, g.H) * 2) break;
                connected.Add(g);
            }
            return CleanName(string.Concat(connected.Select(g => g.Text)));
        }
        return (Name(buyer), Name(seller));
    }

    private static (string buyer, string seller) PartiesInText(string text)
    {
        string Find(string role)
        {
            var match = Regex.Match(text, role + @"(?:信息)?\s*(?:名称)?\s*[:：]\s*([^\r\n]+)");
            return match.Success ? CleanName(match.Groups[1].Value) : "";
        }
        return (Find("购买方"), Find("销售方"));
    }
    private static string CleanName(string source)
    {
        var value = Regex.Split(source, @"(?:纳税人识别号|统一社会信用代码|税号|地址[、，]?电话|开户行及账号)\s*[:：]")[0].Trim(' ', '\t', ':', '：');
        return value.Any(char.IsLetter) && !new[] { "名称", "购买方", "销售方", "付款方", "收款方", "信息" }.Contains(value) ? value : "";
    }
}
