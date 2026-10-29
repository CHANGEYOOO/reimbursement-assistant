using System.IO.Compression;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace ReimburseApp;

internal static class LocalInvoiceContent
{
    internal sealed record Content(string Text, string? Reason = null);
    internal static Content Read(string path)
    {
        try
        {
            if (Path.GetExtension(path).Equals(".xml", StringComparison.OrdinalIgnoreCase)) return InvoiceXml(Parse(File.ReadAllBytes(path)));
            using var archive = ZipFile.OpenRead(path);
            var entries = archive.Entries.ToDictionary(e => e.FullName, StringComparer.Ordinal);
            if (entries.Count > 500 || entries.Keys.Any(n => n.StartsWith('/') || n.Contains('\\') || n.Split('/').Contains("..") || n.Any(char.IsControl))) throw new InvalidDataException();
            long budget = 16 * 1024 * 1024;
            XElement Xml(string name)
            {
                if (!entries.TryGetValue(name, out var entry) || !name.EndsWith(".xml", StringComparison.OrdinalIgnoreCase) || entry.Length > 2 * 1024 * 1024 || (budget -= entry.Length) < 0) throw new InvalidDataException();
                using var stream = entry.Open(); using var buffer = new MemoryStream(); stream.CopyTo(buffer);
                return Parse(buffer.ToArray());
            }
            string Resolve(string value, string from)
            {
                if (value.StartsWith('/') || value.Contains('\\') || value.Contains(':')) throw new InvalidDataException();
                var segments = (from.Contains('/') ? from[..(from.LastIndexOf('/') + 1)] : "").Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
                foreach (var part in value.Split('/')) { if (part == "..") { if (segments.Count == 0) throw new InvalidDataException(); segments.RemoveAt(segments.Count - 1); } else if (part is not "" and not ".") segments.Add(part); }
                var resolved = string.Join('/', segments); if (!entries.ContainsKey(resolved)) throw new InvalidDataException(); return resolved;
            }
            var envelope = Xml("OFD.xml"); var bodies = Children(envelope, "DocBody").ToList();
            if (envelope.Name.LocalName != "OFD" || bodies.Count != 1) throw new InvalidDataException();
            var documentPath = Resolve(Value(bodies[0], "DocRoot"), "OFD.xml"); var document = Xml(documentPath);
            var pages = Children(Child(document, "Pages"), "Page").ToList(); if (pages.Count != 1) return new("", "OFD仅支持单张完整票面，保留待确认。");
            var pageId = Attr(pages[0], "ID"); var page = Xml(Resolve(Attr(pages[0], "BaseLoc"), documentPath));
            var objects = page.Descendants().Where(e => e.Name.LocalName == "TextObject").ToDictionary(e => Attr(e, "ID"), e => string.Concat(e.Descendants().Where(x => x.Name.LocalName == "TextCode").Select(x => x.Value)));
            var titles = page.Descendants().Where(e => e.Name.LocalName == "TextCode").Select(e => e.Value).ToList();
            foreach (var template in Children(Child(document, "CommonData"), "TemplatePage"))
                titles.AddRange(Xml(Resolve(Attr(template, "BaseLoc"), documentPath)).Descendants().Where(e => e.Name.LocalName == "TextCode").Select(e => e.Value));
            var title = titles.FirstOrDefault(t => t.Contains("电子发票") || t.Contains("增值税电子")) ?? "";
            var tagsPath = Resolve(Value(document, "CustomTags"), documentPath); var tags = Xml(tagsPath);
            var tag = Children(tags, "CustomTag").Single(e => Attr(e, "TypeID") == "root");
            var fieldsRoot = Xml(Resolve(Value(tag, "FileLoc"), tagsPath)); if (fieldsRoot.Name.LocalName != "root") throw new InvalidDataException();
            string Field(XElement? node)
            {
                if (node == null) return ""; var refs = node.Elements().ToList();
                if (refs.Count == 0 || refs.Any(r => r.Name.LocalName != "ObjectRef" || Attr(r, "PageRef") != pageId || !objects.ContainsKey(r.Value))) throw new InvalidDataException();
                return string.Concat(refs.Select(r => objects[r.Value]));
            }
            var values = new Dictionary<string, string>();
            foreach (var key in new[] { "InvoiceNo", "InvoiceCode", "IssueDate", "TaxExclusiveTotalAmount", "TaxTotalAmount", "TaxInclusiveTotalAmount" }) values[key] = Field(Child(fieldsRoot, key));
            foreach (var party in new[] { "Buyer", "Seller" }) foreach (var suffix in new[] { "Name", "TaxID" }) values[party + suffix] = Field(Child(Child(fieldsRoot, party), party + suffix));
            foreach (var (label, key) in new[] { ("发票号码", "InvoiceNo"), ("购买方纳税人识别号", "BuyerTaxID"), ("销售方纳税人识别号", "SellerTaxID") })
                if (envelope.Descendants().Any(e => e.Name.LocalName == "CustomData" && Attr(e, "Name") == label && e.Value != values[key])) return new("", "OFD元数据与票面字段冲突。");
            return new(Canonical(title, values));
        }
        catch { return new("", "文件内部结构无法安全解析，保留待确认。"); }
    }
    private static XElement Parse(byte[] bytes)
    {
        if (bytes.Length > 2 * 1024 * 1024) throw new InvalidDataException();
        using var stream = new MemoryStream(bytes); using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 2 * 1024 * 1024 });
        var root = XElement.Load(reader); if (root.Descendants().Take(50001).Count() > 50000 || root.Descendants().Any(e => e.Ancestors().Take(65).Count() > 64)) throw new InvalidDataException(); return root;
    }
    private static XElement? Child(XElement? element, string key) => element?.Elements().SingleOrDefault(e => e.Name.LocalName == key);
    private static IEnumerable<XElement> Children(XElement? element, string key) => element?.Elements().Where(e => e.Name.LocalName == key) ?? [];
    private static string Value(XElement? element, string key) => Child(element, key)?.Value.Trim() ?? "";
    private static string Attr(XElement element, string name) => element.Attributes().FirstOrDefault(a => a.Name.LocalName == name)?.Value ?? "";
    private static Content InvoiceXml(XElement root)
    {
        if (!(new[] { "Invoice", "EInvoice", "root" }).Contains(root.Name.LocalName) || Child(root, "InvoiceNo") == null || Child(root, "TaxInclusiveTotalAmount") == null || Child(root, "Buyer") == null || Child(root, "Seller") == null) return new("", "XML不属于已支持的发票结构。");
        if (Child(root, "InvoiceTitle") != null && Child(root, "Title") != null && Value(root, "InvoiceTitle") != Value(root, "Title")) return new("", "XML发票标题冲突。");
        var scalarKeys = new[] { "InvoiceTitle", "Title", "InvoiceNo", "InvoiceCode", "IssueDate", "TaxExclusiveTotalAmount", "TaxTotalAmount", "TaxInclusiveTotalAmount" };
        if (root.Elements().Where(e => scalarKeys.Contains(e.Name.LocalName)).Any(e => e.HasElements)) return new("", "XML关键字段必须是独立标量。");
        var values = new Dictionary<string, string>();
        foreach (var key in new[] { "InvoiceNo", "InvoiceCode", "IssueDate", "TaxExclusiveTotalAmount", "TaxTotalAmount", "TaxInclusiveTotalAmount" }) values[key] = Value(root, key);
        foreach (var party in new[] { "Buyer", "Seller" }) foreach (var suffix in new[] { "Name", "TaxID" }) values[party + suffix] = Value(Child(root, party), party + suffix);
        if (root.Descendants().Any(e => e.Name.LocalName == "ObjectRef") || values.Values.Any(v => v.Contains('\n') || v.Contains('\r'))) return new("", "XML字段结构无法确认。");
        var title = Value(root, "InvoiceTitle"); if (title.Length == 0) title = Value(root, "Title");
        return new(Canonical(title, values));
    }
    private static string Canonical(string title, Dictionary<string, string> f) => $"{title}\n发票号码：{f["InvoiceNo"]}\n发票代码：{f["InvoiceCode"]}\n开票日期：{f["IssueDate"]}\n购买方信息\n名称：{f["BuyerName"]}\n纳税人识别号：{f["BuyerTaxID"]}\n销售方信息\n名称：{f["SellerName"]}\n纳税人识别号：{f["SellerTaxID"]}\n不含税金额：{f["TaxExclusiveTotalAmount"]}\n税额合计：{f["TaxTotalAmount"]}\n价税合计（小写）：{f["TaxInclusiveTotalAmount"]}";
}
