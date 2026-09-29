using System.Globalization;
using System.Text.RegularExpressions;
using Tesseract;

namespace ReimburseApp;

internal sealed record AmountCandidate(decimal Amount, string Source);

internal sealed record RecognitionResult(
    decimal? Amount,
    string Category,
    string Purpose,
    string? Warning,
    string RecognizedText,
    string? Date,
    IReadOnlyList<AmountCandidate> AmountCandidates);

internal static class Recognition
{
    private const string Number = @"\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?";
    private static readonly Regex Paid = new(@"(?:实付款合计|订单实付款|订单实付|实付款|实付(?!价|满)|已支付|实际支付|支付金额|付款金额|合计支付)\s*[:：]?\s*[¥￥]?\s*[-−–－]?\s*[¥￥]?\s*(" + Number + @")", RegexOptions.Compiled);
    private static readonly Regex OrderPaid = new(@"(?:实付款合计|订单实付款|订单实付|实付款)\s*[:：]?\s*[¥￥]?\s*(" + Number + @")", RegexOptions.Compiled);
    private static readonly Regex OrderTotal = new(@"(?:商品费用合计|商家合计|订单合计)\s*[:：]?\s*[¥￥]?\s*(" + Number + @")", RegexOptions.Compiled);
    private static readonly Regex BareTotal = new(@"^\s*合计\s*[¥￥]\s*(" + Number + @")", RegexOptions.Compiled);
    private static readonly Regex Signed = new(@"^\s*(?:(?:实付|已支付|实际支付|支付金额|付款金额|合计支付|支出|交易金额|扣款金额|金额)\s*[:：]?\s*)?[¥￥]?\s*[-−–－]\s*[¥￥]?\s*(" + Number + @")\s*元?\s*$", RegexOptions.Compiled);
    private static readonly Regex Currency = new(@"[¥￥]\s*[-−–－]?\s*(" + Number + @")", RegexOptions.Compiled);
    private static readonly Regex Yuan = new(@"(?<![0-9A-Za-z])(" + Number + @")\s*元", RegexOptions.Compiled);
    private static readonly Regex DatePattern = new(@"(?<!\d)(20\d{2})[年./-]\s*(\d{1,2})[月./-]\s*(\d{1,2})日?(?!\d)", RegexOptions.Compiled);
    private static readonly string[] PaidLabels = ["实付", "已支付", "实际支付", "支付金额", "付款金额", "合计支付"];
    private static readonly string[] ExcludedLabels = ["优惠", "节省", "返", "券", "劵", "减", "折扣", "原价", "应付", "订单金额", "商品金额", "总价", "退款", "退回", "余额", "实付价", "推荐", "广告"];

    internal static RecognitionResult FromPng(byte[] png, string tessdataDirectory)
    {
        using var engine = new TesseractEngine(tessdataDirectory, "chi_sim+eng", EngineMode.Default);
        using var image = Pix.LoadFromMemory(png);
        using var page = engine.Process(image);
        var result = Suggest(page.GetText());
        using var iterator = page.GetIterator();
        var positioned = new List<(string Text, int X, int Y)>();
        iterator.Begin();
        do
        {
            var value = iterator.GetText(PageIteratorLevel.TextLine)?.Trim();
            if (!string.IsNullOrEmpty(value) && iterator.TryGetBoundingBox(PageIteratorLevel.TextLine, out var box))
                positioned.Add((value, (box.X1 + box.X2) / 2, (box.Y1 + box.Y2) / 2));
        } while (iterator.Next(PageIteratorLevel.TextLine));
        var positionedAmount = AlignedPaidAmount(positioned, image.Width, image.Height);
        if (positionedAmount is decimal amount)
            return result with { Amount = amount, AmountCandidates = [], Warning = result.Category == "待分类" ? "用途分类待确认" : null };
        return result;
    }

    private static decimal? AlignedPaidAmount(IReadOnlyList<(string Text, int X, int Y)> lines, int width, int height)
    {
        if (width <= 0 || height <= 0) return null;
        var text = string.Join("\n", lines.Select(line => line.Text));
        if (text.Contains("全部订单") || text.Contains("订单列表") ||
            new[] { "退款成功", "已退款", "收款成功", "已收款", "转入成功", "收入到账" }.Any(text.Contains)) return null;
        var direct = Collect(lines.Select(line => line.Text), OrderPaid);
        if (direct.Count == 1) return direct.Single();
        if (direct.Count > 1) return null;
        var aligned = new HashSet<decimal>();
        foreach (var label in lines.Where(line => line.Text.Contains("实付款") && !line.Text.Contains("实付价")))
        {
            // A Tesseract text line may contain both the discount and the final amount.
            var own = Currency.Matches(label.Text);
            if (own.Count > 1 && label.Text.Contains("减") &&
                decimal.TryParse(own[^1].Groups[1].Value.Replace(",", ""), NumberStyles.AllowDecimalPoint,
                    CultureInfo.InvariantCulture, out var finalAmount)) aligned.Add(finalAmount);
            foreach (var value in lines.Where(value => value.Text != label.Text &&
                         Math.Abs(value.Y - label.Y) < height * 0.016 &&
                         value.X > Math.Max(width * 0.65, label.X + width * 0.2)))
            {
                var amounts = Values(value.Text, Currency);
                if (amounts.Count == 1) aligned.Add(amounts.Single());
            }
        }
        return aligned.Count == 1 ? aligned.Single() : null;
    }

    internal static RecognitionResult Suggest(string text)
    {
        var lines = text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        var category = Category(text);
        var warnings = new List<string>();
        var orderPaid = Collect(lines, OrderPaid);
        var separatedPaid = orderPaid.Count == 0 ? SeparatedPaidAmount(lines) : null;
        var separatedTotal = SeparatedTotalAmount(lines);
        var directPaid = Collect(lines, Paid);
        var hasUnpairedPaidLabel = lines.Any(line => HasPaidLabel(line) && Values(line, Paid).Count == 0);
        var paid = new HashSet<decimal>(directPaid);
        if (hasUnpairedPaidLabel)
        {
            // OCR sometimes puts the amount below its label. Keep ambiguous cases for manual review.
            paid.UnionWith(Collect(lines.Where(line => !Excluded(line)), Currency, Yuan, Signed));
        }

        decimal? amount;
        var orderList = lines.Any(line => line.Trim() == "全部订单" || line.Contains("订单列表"));
        var incoming = new[] { "退款成功", "已退款", "收款成功", "已收款", "转入成功", "收入到账" }.Any(text.Contains);
        if (incoming)
        {
            amount = null;
            warnings.Add("退款或收入记录，请人工核对");
        }
        else if (orderList)
        {
            amount = null;
            warnings.Add("订单列表包含多笔订单，请点选正确金额并核对");
        }
        else if (orderPaid.Count == 1 || separatedPaid != null)
        {
            amount = orderPaid.Count == 1 ? orderPaid.Single() : separatedPaid;
            if (separatedPaid != null) warnings.Add("实付款与金额分行显示，请人工核对");
        }
        else if (orderPaid.Count > 1)
        {
            amount = null;
            warnings.Add("识别到多个不同的实付金额，请人工核对");
        }
        else if (paid.Count == 1)
        {
            amount = paid.Single();
            if (hasUnpairedPaidLabel) warnings.Add("金额未紧邻实付标识，请人工核对");
            if (HasNegativePaidLine(lines)) warnings.Add("负数支出金额，请人工核对");
        }
        else if (paid.Count > 1)
        {
            amount = null;
            warnings.Add("识别到多个不同的实付金额，请人工核对");
        }
        else
        {
            var usable = lines.Where(line => !Excluded(line)).ToArray();
            var signed = Collect(usable, Signed);
            var currency = Collect(usable, Currency);
            var totals = Collect(lines, OrderTotal, BareTotal);
            var ledgerDebit = LedgerDebit(lines, text);
            if (separatedTotal != null)
            {
                amount = separatedTotal;
                warnings.Add("仅识别到订单合计，未见实付标识，请人工核对");
            }
            else if (totals.Count == 1)
            {
                amount = totals.Single();
                warnings.Add("仅识别到订单合计，未见实付标识，请人工核对");
            }
            else if (totals.Count > 1)
            {
                amount = null;
                warnings.Add("识别到多个订单合计，请人工核对");
            }
            else if (ledgerDebit != null)
            {
                amount = ledgerDebit;
                warnings.Add("负数支出金额，请人工核对");
            }
            else if (signed.Count == 1)
            {
                amount = signed.Single();
                warnings.Add("负数支出金额，请人工核对");
            }
            else if (signed.Count > 1)
            {
                amount = null;
                warnings.Add("识别到多个不同的支出金额，请人工核对");
            }
            else if (currency.Count == 1 && !lines.Any(HasPaidLabel))
            {
                amount = currency.Single();
                warnings.Add("金额未标明实付，请人工核对");
            }
            else
            {
                amount = null;
                warnings.Add("未能确定实付金额，请人工填写");
            }
        }

        if (category == "待分类") warnings.Add("用途分类待确认");
        return new RecognitionResult(amount, category, category == "待分类" ? "" : category + "费用",
            warnings.Count == 0 ? null : string.Join("；", warnings), text, TransactionDate(lines),
            amount == null ? Candidates(lines) : []);
    }

    private static bool HasNegativePaidLine(IEnumerable<string> lines) =>
        lines.Any(line => HasPaidLabel(line) && Regex.IsMatch(line, @"[¥￥]?\s*[-−–－]\s*[¥￥]?\s*\d"));

    private static string? TransactionDate(string[] lines)
    {
        var dates = new List<(int Line, string Value)>();
        for (var index = 0; index < lines.Length; index++)
            foreach (Match match in DatePattern.Matches(lines[index]))
                if (int.TryParse(match.Groups[1].Value, out var year) &&
                    int.TryParse(match.Groups[2].Value, out var month) &&
                    int.TryParse(match.Groups[3].Value, out var day) &&
                    DateOnly.TryParseExact($"{year:D4}-{month:D2}-{day:D2}", "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _))
                    dates.Add((index, $"{year:D4}-{month:D2}-{day:D2}"));

        foreach (var label in new[] { "支付时间", "付款时间", "交易时间", "扣款时间", "转账时间", "成交时间" })
        {
            var near = lines.Select((line, index) => (line, index))
                .Where(item => item.line.Contains(label))
                .Select(item => dates.FirstOrDefault(date => date.Line >= item.index && date.Line <= item.index + 12).Value)
                .Where(date => date != null).Distinct().ToArray();
            if (near.Length > 0) return near.Length == 1 ? near[0] : null;
        }
        var unique = dates.Select(date => date.Value).Distinct().ToArray();
        return unique.Length == 1 ? unique[0] : null;
    }

    private static string Category(string text)
    {
        (string Category, string[] Words)[] rules = [
            ("交通", ["打车", "网约车", "出租车", "地铁", "公交", "高铁", "火车", "机票", "车费", "滴滴"]),
            ("餐食", ["餐饮", "餐厅", "饭店", "外卖", "午餐", "晚餐", "早餐", "美食", "古茗", "奶茶", "咖啡", "茶饮"]),
            ("住宿", ["酒店", "住宿", "宾馆", "民宿"]),
            ("采购", ["采购", "办公用品", "文具", "设备", "耗材"])
        ];
        return rules.FirstOrDefault(rule => rule.Words.Any(word => text.Contains(word, StringComparison.OrdinalIgnoreCase))).Category ?? "待分类";
    }

    private static bool Excluded(string line) => ExcludedLabels.Any(line.Contains) || line.Contains("元卷");
    private static bool HasPaidLabel(string line) => !line.Contains("实付价") && !line.Contains("实付满") && PaidLabels.Any(line.Contains);

    private static decimal? SeparatedPaidAmount(string[] lines)
    {
        var labels = lines.Select((line, index) => (line, index))
            .Where(item => item.line.Contains("实付款") && !item.line.Contains("实付价")).ToArray();
        if (labels.Length != 1) return null;
        var (label, index) = labels[0];
        var sameLineTotal = Values(label, new Regex(@"合计\s*[¥￥]?\s*(" + Number + @")"));
        if (sameLineTotal.Count == 1) return sameLineTotal.Single();
        var nextLineTotal = lines.Skip(index + 1).Take(2)
            .SelectMany(line => Values(line, new Regex(@"合计\s*[¥￥]?\s*(" + Number + @")"))).Distinct().ToArray();
        if (nextLineTotal.Length == 1) return nextLineTotal[0];
        var nearby = lines.Skip(Math.Max(0, index - 2)).Take(Math.Min(lines.Length, index + 8) - Math.Max(0, index - 2))
            .Where(line => !Excluded(line)).SelectMany(line => Values(line, Currency)).ToArray();
        return nearby.Length > 0 ? nearby[^1] : null;
    }

    private static decimal? SeparatedTotalAmount(string[] lines)
    {
        var labels = lines.Select((line, index) => (line, index)).Where(item => item.line.Trim() == "合计").ToArray();
        if (labels.Length != 1) return null;
        var next = lines.Skip(labels[0].index + 1).Take(1).SelectMany(line => Values(line, Currency)).ToArray();
        return next.Length == 1 ? next[0] : null;
    }

    private static decimal? LedgerDebit(string[] lines, string text)
    {
        if (!text.Contains("交易成功") && !text.Contains("支付成功")) return null;
        var orderAmountIndex = Array.FindIndex(lines, line => line.Contains("订单金额"));
        if (orderAmountIndex < 0) return null;
        var above = Collect(lines.Take(orderAmountIndex), Signed);
        return above.Count == 1 ? above.Single() : null;
    }

    private static IReadOnlyList<AmountCandidate> Candidates(string[] lines)
    {
        var text = string.Join("\n", lines);
        if (new[] { "退款成功", "已退款", "收款成功", "已收款", "转入成功", "收入到账" }.Any(text.Contains)) return [];
        var orderPaid = Collect(lines, OrderPaid);
        if (orderPaid.Count > 0) return lines.SelectMany(line => Values(line, OrderPaid))
            .Distinct().Take(5).Select(amount => new AmountCandidate(amount, "整单实付")).ToArray();
        var ranked = new List<(decimal Amount, string Source, int Score, int Index)>();
        for (var index = 0; index < lines.Length; index++)
        {
            var line = lines[index];
            void Add(Regex pattern, string source, int score)
            {
                foreach (var value in Values(line, pattern))
                    if (value > 0) ranked.Add((value, source, score, index));
            }
            Add(OrderPaid, "整单实付", 100);
            if (!Excluded(line))
            {
                Add(Paid, "实付", 80);
                Add(Signed, "支出", 75);
                Add(OrderTotal, "订单合计", 65);
                Add(BareTotal, "订单合计", 65);
            }
        }
        return ranked.OrderByDescending(item => item.Score).ThenBy(item => item.Index)
            .DistinctBy(item => item.Amount).Take(5)
            .Select(item => new AmountCandidate(item.Amount, item.Source)).ToArray();
    }

    private static HashSet<decimal> Collect(IEnumerable<string> lines, params Regex[] patterns)
    {
        var result = new HashSet<decimal>();
        foreach (var line in lines)
            foreach (var pattern in patterns)
                result.UnionWith(Values(line, pattern));
        return result;
    }

    private static HashSet<decimal> Values(string line, Regex pattern)
    {
        var result = new HashSet<decimal>();
        foreach (Match match in pattern.Matches(line))
            if (decimal.TryParse(match.Groups[1].Value.Replace(",", ""), NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var amount))
                result.Add(amount);
        return result;
    }

    internal static void SelfCheck()
    {
        if (Suggest("支付成功\n-￥32.50\n交易时间 2026-09-28").Amount != 32.50m ||
            Suggest("实付 ¥32.50\n优惠 ¥4.00").Amount != 32.50m ||
            Suggest("-￥32.50\n-￥36.00").Amount != null ||
            Suggest("支付时间 2026-02-30").Date != null ||
            Suggest("商品实付价72\n订单实付款417").Amount != 417m ||
            Suggest("全部订单\n实付款108\n实付款29.9").AmountCandidates.Count != 2 ||
            Suggest("商家合计14.2\n推荐商品¥18.8").Amount != 14.2m ||
            Suggest("退款成功\n-￥32.50").Amount != null ||
            Suggest("实付款 共减¥88\n¥359\n-￥60\n-￥28\n¥271").Amount != 271m ||
            Suggest("合计\n已优惠17.5元 ¥21.18\n-￥13").Amount != 21.18m ||
            Suggest("交易成功\n-5.09\n订单金额\n6.00\n支付遇财神\n-0.91").Amount != 5.09m ||
            Suggest("实付款\n共减¥0.3合计¥248.7").Amount != 248.7m ||
            Suggest("实付¥10.93\n实付¥7.04\n实付款¥18.97").Amount != 18.97m ||
            AlignedPaidAmount([("实付款 共减¥88", 250, 400), ("¥271", 850, 400)], 1000, 2000) != 271m)
            throw new InvalidOperationException("识别规则自检失败");
    }
}
