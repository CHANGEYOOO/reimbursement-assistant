using System.Globalization;
using System.Text.RegularExpressions;
using Tesseract;

namespace ReimburseApp;

public sealed record AmountCandidate(decimal Amount, string Source);
public sealed record RecognitionResult(decimal? Amount, string Category, string Purpose, string? Warning,
    string RecognizedText, string? Date, IReadOnlyList<AmountCandidate> AmountCandidates);
public readonly record struct PositionedText(string Text, double X, double Y);

public static class Recognition
{
    private const string Number = @"\d[\d,]*(?:\.\d{1,2})?";
    private static readonly Regex Paid = new(@"(?:实付款合计|订单实付款|订单实付|实付款|实付(?!价)|已支付|实际支付|支付金额|付款金额|合计支付)[ \t]*[:：]?[ \t]*[¥￥]?[ \t]*(" + Number + @")");
    private static readonly Regex OrderPaid = new(@"(?:实付款合计|订单实付款|订单实付|实付款)\s*[:：]?[ \t]*[¥￥]?[ \t]*(" + Number + @")");
    private static readonly Regex OrderTotal = new(@"(?:商品费用合计|商家合计|订单合计)[ \t]*[:：]?[ \t]*[¥￥]?[ \t]*(" + Number + @")");
    private static readonly Regex Signed = new(@"^\s*(?:(?:实付|已支付|实际支付|支付金额|付款金额|合计支付|支出|交易金额|扣款金额|金额)\s*[:：]?\s*)?(?:[¥￥]\s*)?[-−–]\s*(?:[¥￥]\s*)?(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)\s*元?\s*$");
    private static readonly Regex Currency = new(@"[¥￥]\s*(" + Number + @")");
    private static readonly Regex Yuan = new(@"(?<![0-9A-Za-z])(" + Number + @")\s*元");
    private static readonly Regex DatePattern = new(@"(?<!\d)(20\d{2})[年./-]\s*(\d{1,2})[月./-]\s*(\d{1,2})日?(?!\d)");
    private static readonly string[] Incoming = ["退款成功", "已退款", "收款成功", "已收款", "转入成功", "收入到账"];
    private static readonly string[] PaidLabels = ["实付", "已支付", "实际支付", "支付金额", "付款金额", "合计支付"];
    private static readonly string[] ExcludedLabels = ["优惠", "节省", "返", "券", "劵", "减", "折扣", "原价", "应付", "订单金额", "商品金额", "总价", "退款", "退回", "实付价", "推荐", "广告"];

    public static RecognitionResult FromPng(byte[] png, string tessdataDirectory)
    {
        using var engine = new TesseractEngine(tessdataDirectory, "chi_sim+eng", EngineMode.Default);
        using var image = Pix.LoadFromMemory(png);
        using var page = engine.Process(image);
        using var iterator = page.GetIterator();
        var lines = new List<PositionedText>();
        iterator.Begin();
        do
        {
            var value = iterator.GetText(PageIteratorLevel.TextLine)?.Trim();
            if (!string.IsNullOrEmpty(value) && iterator.TryGetBoundingBox(PageIteratorLevel.TextLine, out var box))
                lines.Add(new(value, (box.X1 + box.X2) / (2.0 * image.Width), 1 - (box.Y1 + box.Y2) / (2.0 * image.Height)));
        } while (iterator.Next(PageIteratorLevel.TextLine));
        var text = lines.Count == 0 ? page.GetText() : string.Join("\n", lines.Select(line => line.Text));
        var result = Suggest(text);
        if (PositionedAmount(lines) is { } resolved)
        {
            var warning = string.Join("；", new[] { resolved.Warning, result.Category == "待分类" ? "用途分类待确认" : null }.Where(s => !string.IsNullOrEmpty(s)));
            result = result with { Amount = resolved.Amount, Warning = warning.Length == 0 ? null : warning };
        }
        return result with { AmountCandidates = result.Amount == null ? Candidates(lines) : [] };
    }

    public static RecognitionResult Suggest(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        var category = Category(text);
        var direct = Collect(lines.Where(line => !line.Contains("实付价")), Paid);
        var unpaired = lines.Any(line => HasPaidLabel(line) && Values(line, Paid).Count == 0);
        var paid = new HashSet<decimal>(direct);
        if (unpaired) paid.UnionWith(Collect(lines.Where(line => !Excluded(line)), Currency, Yuan));
        var warnings = new List<string>();
        if (unpaired && paid.Count == 1) warnings.Add("金额未紧邻实付标识，请人工核对");
        decimal? amount;
        if (Incoming.Any(text.Contains))
        {
            amount = null;
            warnings.Add("退款或收入记录，请人工核对");
        }
        else if (lines.Any(line => line.Trim() == "全部订单" || line.Contains("订单列表")))
        {
            amount = null;
            warnings.Add("订单列表包含多笔订单，请点选正确金额并核对");
        }
        else if (paid.Count == 1) amount = paid.Single();
        else if (paid.Count > 1)
        {
            amount = null;
            warnings.Add("识别到多个不同的实付金额，请人工核对");
        }
        else
        {
            var signed = Collect(lines.Where(line => !Excluded(line)), Signed);
            var totals = Collect(lines, OrderTotal);
            var all = Collect(lines.Where(line => !Excluded(line)), Currency);
            if (signed.Count == 1) amount = signed.Single();
            else if (signed.Count > 1) { amount = null; warnings.Add("识别到多个不同的支出金额，请人工核对"); }
            else if (totals.Count == 1) { amount = totals.Single(); warnings.Add("仅识别到订单合计，未见实付标识，请人工核对"); }
            else if (totals.Count > 1) { amount = null; warnings.Add("识别到多个订单合计，请人工核对"); }
            else if (all.Count == 1 && !lines.Any(HasPaidLabel)) { amount = all.Single(); warnings.Add("金额未标明实付，请人工核对"); }
            else { amount = null; warnings.Add("未能确定实付金额，请人工填写"); }
        }
        if (category == "待分类") warnings.Add("用途分类待确认");
        var positions = lines.Select((line, index) => new PositionedText(line, 0.5, 1 - index / (double)Math.Max(1, lines.Length))).ToArray();
        return new(amount, category, category == "待分类" ? "" : category + "费用", warnings.Count == 0 ? null : string.Join("；", warnings), text, TransactionDate(lines),
            amount == null && !Incoming.Any(text.Contains) ? Candidates(positions) : []);
    }

    public static (decimal Amount, string? Warning)? PositionedAmount(IReadOnlyList<PositionedText> lines)
    {
        var allText = string.Join("\n", lines.Select(line => line.Text));
        if (lines.Any(line => line.Text is "全部订单" or "订单列表") || Incoming.Any(allText.Contains)) return null;
        var paid = Collect(lines.Select(line => line.Text), OrderPaid);
        if (paid.Count == 1) return (paid.Single(), null);
        foreach (var label in lines.Where(line => line.Text.Contains("实付款") && !line.Text.Contains("实付价")))
            foreach (var value in lines.Where(value => Math.Abs(value.Y - label.Y) < 0.016 && value.X > Math.Max(0.65, label.X + 0.2)).OrderByDescending(value => value.X))
            {
                var totals = Values(value.Text, new Regex(@"合计\s*[¥￥]?\s*(" + Number + @")"));
                if (totals.Count > 0) return (totals.First(), null);
                var currency = Values(value.Text, Currency);
                if (currency.Count == 1) return (currency.Single(), null);
            }
        if (allText.Contains("支付成功") || allText.Contains("交易成功"))
        {
            var debits = lines.Where(line => line.Y > 0.68).SelectMany(line => Values(line.Text, Signed).Select(value => (Amount: value, line.Y))).OrderByDescending(value => value.Y).ToArray();
            if (debits.Length > 0) return (debits[0].Amount, null);
        }
        foreach (var label in lines.Where(line => line.Text == "合计"))
            foreach (var value in lines.Where(value => Math.Abs(value.Y - label.Y) < 0.016 && value.X > 0.65))
            {
                var amounts = Values(value.Text, Currency);
                if (amounts.Count == 1) return (amounts.Single(), "仅识别到订单合计，未见实付标识，请人工核对");
            }
        var orderTotals = Collect(lines.Select(line => line.Text), new Regex(@"^\s*合计\s*[¥￥]\s*(" + Number + @")"));
        return orderTotals.Count == 1 ? (orderTotals.Single(), "仅识别到订单合计，未见实付标识，请人工核对") : null;
    }

    public static IReadOnlyList<AmountCandidate> Candidates(IReadOnlyList<PositionedText> lines)
    {
        var ranked = new List<(decimal Amount, string Source, int Score, int Index)>();
        for (var index = 0; index < lines.Count; index++)
        {
            var line = lines[index];
            void Add(string source, int score, Regex pattern)
            {
                foreach (var amount in Values(line.Text, pattern)) if (amount > 0) ranked.Add((amount, source, score, index));
            }
            Add("整单实付", 100, OrderPaid);
            if (line.Text.Contains("实付") && !line.Text.Contains("实付满") && !line.Text.Contains("实付价")) Add("实付", 80, Paid);
            if (!Excluded(line.Text))
            {
                Add("支出", line.Y > 0.6 ? 85 : 55, Signed);
                Add("订单合计", 65, new(@"^\s*合计\s*[¥￥]\s*(" + Number + @")"));
            }
            if (line.Text.Contains("实付款") || line.Text == "合计")
                foreach (var nearby in lines.Where(value => Math.Abs(value.Y - line.Y) < 0.016 && value.X > Math.Max(0.65, line.X + 0.2)))
                {
                    var amounts = Values(nearby.Text, Currency);
                    if (amounts.Count == 1) ranked.Add((amounts.Single(), line.Text == "合计" ? "订单合计" : "整单实付", 90, index));
                }
            if (Excluded(line.Text)) continue;
            Add("扣款数字", 55, new(@"(?<![\dA-Za-z])[-−–]\s*[¥￥]?\s*(\d{1,6}(?:\.\d{1,2})?)(?![\d.,A-Za-z])"));
            Add("带货币符号", 45, new(@"[¥￥]\s*(\d{1,6}(?:,\d{3})*(?:\.\d{1,2})?)(?![\d,])"));
            Add("金额文字", 40, new(@"(?<![\dA-Za-z])(\d{1,6}(?:\.\d{1,2})?)\s*元"));
            Add("小数金额", 30, new(@"(?<![\d./-])(\d{1,6}\.\d{1,2})(?![\d./-])"));
            if (lines.Skip(Math.Max(0, index - 2)).Take(Math.Min(index, 2)).Any(value => HasPaidLabel(value.Text)))
                Add("支付附近金额", 25, new(@"^\s*(\d{1,6})\s*$"));
        }
        return ranked.OrderByDescending(item => item.Score).ThenBy(item => item.Index).DistinctBy(item => item.Amount).Take(5).Select(item => new AmountCandidate(item.Amount, item.Source)).ToArray();
    }

    private static string? TransactionDate(string[] lines)
    {
        var dates = lines.SelectMany((line, index) => DatePattern.Matches(line).Cast<Match>().Select(match => (Line: index, Value: NormalizedDate(match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value))))
            .Where(item => item.Value != null).ToArray();
        foreach (var label in new[] { "支付时间", "付款时间", "交易时间", "扣款时间", "转账时间", "成交时间" })
        {
            var found = lines.Select((line, index) => (line, index)).Where(item => item.line.Contains(label))
                .Select(item => dates.FirstOrDefault(date => date.Line >= item.index && date.Line <= item.index + 12).Value).Where(value => value != null).Distinct().ToArray();
            if (found.Length > 0) return found.Length == 1 ? found[0] : null;
        }
        var unique = dates.Select(date => date.Value).Distinct().ToArray();
        return unique.Length == 1 ? unique[0] : null;
    }

    public static string? NormalizedDate(string year, string month, string day) => int.TryParse(year, out var y) && int.TryParse(month, out var m) && int.TryParse(day, out var d) && y is >= 1900 and <= 2099 && DateOnly.TryParseExact($"{y:D4}-{m:D2}-{d:D2}", "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _) ? $"{y:D4}-{m:D2}-{d:D2}" : null;
    public static bool IsValidDate(string value) => Regex.IsMatch(value, @"^\d{4}-\d{2}-\d{2}$") && DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) && date.Year is >= 1900 and <= 2099;
    private static bool Excluded(string line) => ExcludedLabels.Any(line.Contains) || line.Contains("元卷");
    private static bool HasPaidLabel(string line) => !line.Contains("实付价") && !line.Contains("实付满") && PaidLabels.Any(line.Contains);
    private static HashSet<decimal> Collect(IEnumerable<string> lines, params Regex[] patterns) => lines.SelectMany(line => patterns.SelectMany(pattern => Values(line, pattern))).ToHashSet();
    private static HashSet<decimal> Values(string text, Regex pattern) => pattern.Matches(text).Cast<Match>().Select(match => decimal.TryParse(match.Groups[1].Value.Replace(",", ""), NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var amount) ? (decimal?)amount : null).OfType<decimal>().ToHashSet();

    private static string Category(string text)
    {
        string[] ignored = ["推荐", "广告", "优惠", "红包", "积分", "退款", "退货", "售后", "价格明细", "实付", "总价", "合计", "账单分类", "订单编号", "交易单号", "支付时间", "付款方式", "配送地址", "收货地址", "发票", "搜索订单", "全部订单", "飞猪旅行", "商品说明", "商户全称", "收单机构", "团购特价", "商家小程序"];
        string[] objects = ["道具", "器材", "设备", "工具", "电子", "数码", "文具", "家具", "家居", "灯具", "台灯", "布料", "地毯", "支架", "容器", "空瓶", "分装瓶", "玻璃瓶", "杯子", "餐具", "雨衣", "牙膏", "棉签", "清洁用品", "防尘罩", "读卡器", "硬盘盒", "亚克力", "花瓶", "仿真花", "干花", "纤维板", "板夹", "托盘", "切菜机", "桌布", "日用百货", "办公用品", "耗材"];
        (string Category, string[] Words)[] strong = [
            ("交通", ["打车", "网约车", "出租车", "地铁", "公交", "高铁", "火车票", "机票", "车费", "滴滴", "渡口", "渡轮", "停车费", "货拉拉", "乘车后付款", "高速通行费", "过路费", "ETC"]),
            ("餐食", ["食品", "食物", "餐饮", "小吃", "快餐", "火锅", "麻辣烫", "拌饭", "盖浇饭", "面馆", "烧烤", "汉堡", "披萨", "奶茶", "咖啡", "果汁", "饮料", "茶饮", "零食", "面包", "甜品", "蛋糕", "水果", "酒类", "酒庄", "张裕", "双人餐", "把子肉", "酸汤", "美食市集", "古茗"]),
            ("住宿", ["酒店", "住宿", "宾馆", "民宿", "房费"])
        ];
        (string Category, string[] Words)[] weak = [("餐食", ["餐厅", "饭店", "外卖", "午餐", "晚餐", "早餐", "美食"]), ("道具采购", ["超市"])];
        var scores = new Dictionary<string, int>();
        foreach (var line in text.Split('\n'))
        {
            if (ignored.Any(line.Contains)) continue;
            if (objects.Any(word => line.Contains(word, StringComparison.OrdinalIgnoreCase))) { scores["道具采购"] = scores.GetValueOrDefault("道具采购") + 3; continue; }
            foreach (var (category, words) in strong) if (words.Any(word => line.Contains(word, StringComparison.OrdinalIgnoreCase))) scores[category] = scores.GetValueOrDefault(category) + 3;
            foreach (var (category, words) in weak) if (words.Any(word => line.Contains(word, StringComparison.OrdinalIgnoreCase))) scores[category] = scores.GetValueOrDefault(category) + 1;
        }
        var ranked = scores.OrderByDescending(item => item.Value).ToArray();
        return ranked.Length > 0 && ranked[0].Value >= 3 && ranked[0].Value >= (ranked.Length > 1 ? ranked[1].Value : 0) + 2 ? ranked[0].Key : "待分类";
    }

    public static void SelfCheck()
    {
        if (Suggest("支付成功\n-￥32.50\n交易时间 2026-09-28").Amount != 32.50m || Suggest("雨衣\n实付 ¥32.50").Category != "道具采购" ||
            Suggest("汉堡\n实付¥32.50\n优惠¥4.00").Category != "餐食" || Suggest("咖啡分装瓶\n实付¥19.00").Category != "道具采购" ||
            Suggest("-￥32.50\n-￥36.00").Amount != null || Suggest("支付时间 2026-02-30").Date != null ||
            Suggest("全部订单\n实付款108\n实付款29.9").AmountCandidates.Count != 2 || Suggest("退款成功\n实付¥32.50").Amount != null ||
            Suggest("金额候选\n39.50\n46.20").AmountCandidates.Count != 2 || Suggest("-32.50").Warning?.Contains("负数") == true ||
            PositionedAmount([new("实付款 共减¥88", 0.25, 0.8), new("¥271", 0.85, 0.8)])?.Amount != 271m)
            throw new InvalidOperationException("订单识别规则自检失败");
    }
}
