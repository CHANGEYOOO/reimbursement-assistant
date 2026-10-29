using System.IO.Compression;
using ReimburseApp;

internal static class StructuredInvoiceChecks
{
    internal static void Run()
    {
        static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
        var root = Path.Combine(Path.GetTempPath(), "invoice-structure-parity-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        var xml = """
            <Invoice><InvoiceTitle>电子发票（普通发票）</InvoiceTitle><InvoiceNo>12345678901234567890</InvoiceNo><IssueDate>2026-10-27</IssueDate>
            <Buyer><BuyerName>测试购买企业</BuyerName><BuyerTaxID>123456789012345678</BuyerTaxID></Buyer><Seller><SellerName>测试销售企业</SellerName><SellerTaxID>987654321098765432</SellerTaxID></Seller>
            <TaxExclusiveTotalAmount>100.00</TaxExclusiveTotalAmount><TaxTotalAmount>6.00</TaxTotalAmount><TaxInclusiveTotalAmount>106.00</TaxInclusiveTotalAmount></Invoice>
            """;
        var source = Path.Combine(root, "invoice.xml"); File.WriteAllText(source, xml);
        var reading = InvoiceRecognition.Read(source, "unused");
        Check(reading.Accepted && reading.Amount == 106m && reading.Buyer == "测试购买企业", "XML structure and metadata parsed");
        File.WriteAllText(source, xml.Replace("普通发票", "增值税专用发票"));
        Check(InvoiceRecognition.Read(source, "unused").Accepted, "Digital special with verified fields accepted");
        var canonicalSpecial = LocalInvoiceContent.Read(source).Text;
        Check(InvoiceRecognition.ClassifyKind(canonicalSpecial).kind == InvoiceDocumentKind.Invoice, "Special natural text uses strict field validation");
        Check(InvoiceRecognition.ClassifyKind(canonicalSpecial.Replace("税额合计：6.00", "税额合计：7.00")).kind == InvoiceDocumentKind.Unknown, "Special mismatched tax stays uncertain");
        File.WriteAllText(source, xml.Replace("106.00", "107.00"));
        Check(InvoiceRecognition.Read(source, "unused").Kind == InvoiceDocumentKind.Unknown, "XML mismatched arithmetic uncertain");
        File.WriteAllText(source, "<!DOCTYPE Invoice [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" + xml.Replace("测试购买企业", "&x;"));
        Check(InvoiceRecognition.Read(source, "unused").Kind == InvoiceDocumentKind.Unknown, "XML DTD blocked");
        File.WriteAllText(source, xml.Replace("<Invoice>", "<Order>").Replace("</Invoice>", "</Order>"));
        Check(InvoiceRecognition.Read(source, "unused").Kind == InvoiceDocumentKind.Unknown, "Order XML not invoice by shared labels");
        var ofd = Path.Combine(root, "invoice.ofd");
        using (var zip = ZipFile.Open(ofd, ZipArchiveMode.Create))
        {
            void Put(string name, string value) { using var writer = new StreamWriter(zip.CreateEntry(name).Open()); writer.Write(value); }
            Put("OFD.xml", "<OFD><DocBody><DocRoot>Doc/Document.xml</DocRoot></DocBody></OFD>");
            Put("Doc/Document.xml", "<Document><Pages><Page ID='1' BaseLoc='Pages/Page.xml'/></Pages><CustomTags>Tags.xml</CustomTags></Document>");
            var fields = new Dictionary<string, string> { ["InvoiceNo"] = "12345678901234567890", ["IssueDate"] = "2026-10-27", ["BuyerName"] = "测试购买企业", ["BuyerTaxID"] = "123456789012345678", ["SellerName"] = "测试销售企业", ["SellerTaxID"] = "987654321098765432", ["TaxExclusiveTotalAmount"] = "100.00", ["TaxTotalAmount"] = "6.00", ["TaxInclusiveTotalAmount"] = "106.00" };
            Put("Doc/Pages/Page.xml", "<Page><Content><TextObject ID='title'><TextCode>电子发票（普通发票）</TextCode></TextObject>" + string.Concat(fields.Select(p => $"<TextObject ID='{p.Key}'><TextCode>{p.Value}</TextCode></TextObject>")) + "</Content></Page>");
            Put("Doc/Tags.xml", "<CustomTags><CustomTag TypeID='root'><FileLoc>Fields.xml</FileLoc></CustomTag></CustomTags>");
            string Field(string key) => $"<{key}><ObjectRef PageRef='1'>{key}</ObjectRef></{key}>";
            Put("Doc/Fields.xml", "<root>" + Field("InvoiceNo") + Field("IssueDate") + "<Buyer>" + Field("BuyerName") + Field("BuyerTaxID") + "</Buyer><Seller>" + Field("SellerName") + Field("SellerTaxID") + "</Seller>" + Field("TaxExclusiveTotalAmount") + Field("TaxTotalAmount") + Field("TaxInclusiveTotalAmount") + "</root>");
        }
        Check(InvoiceRecognition.Read(ofd, "unused").Accepted, "OFD ObjectRef data joined to exact page objects");
        Console.WriteLine("XML/OFD structure checks passed; fixtures retained at " + root);
    }
}
