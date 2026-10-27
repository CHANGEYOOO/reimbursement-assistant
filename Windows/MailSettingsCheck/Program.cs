using MailKit;
using MimeKit;
using ReimburseApp;

MailSettingsChecks.Run();

internal static class MailSettingsChecks
{
    internal static void Run()
    {
        AppSettings.ValidateAi("https://api.deepseek.com/chat/completions", "deepseek-flash", "test-key");
        foreach (var endpoint in new[] { "http://example.com/api", "https://user:pass@example.com/api", "https://example.com/api?token=x", "https://example.com/api#fragment", "relative/path" })
            Reject(() => AppSettings.ValidateAi(endpoint, "model", "key"));
        Reject(() => AppSettings.ValidateAi("https://example.com/api", "two words", "key"));
        Reject(() => AppSettings.ValidateAi("https://example.com/api", "model", "bad\nkey"));
        AppSettings.Validate(new AppSettings());
        Reject(() => AppSettings.Validate(new AppSettings { CacheLimitMb = double.NaN }));
        Reject(() => AppSettings.Validate(new AppSettings { CacheLimitMb = 0 }));
        MailService.ValidateCredentials("user@qq.com", "authorization-code");
        MailService.ValidateCredentials("user@vip.qq.com", "authorization-code");
        MailService.ValidateCredentials("user@foxmail.com", "authorization-code");
        Reject(() => MailService.ValidateCredentials("user@example.com", "code"));
        Reject(() => MailService.ValidateCredentials("user@qq.com", ""));
        Reject(() => MailService.ValidateCredentials("user@qq.com", "bad\r\ncode"));
        Check(MailService.IsCandidate(Part("ordinary.pdf", "application", "pdf"), "您的电子发票"), "Invoice subject allows UUID PDF candidate");
        Check(!MailService.IsCandidate(Part("行程单.pdf", "application", "pdf"), "您的发票"), "Itinerary metadata excluded");
        Check(!MailService.IsCandidate(Part("发票报销单.pdf", "application", "pdf"), "发票"), "Report excluded");
        Check(!MailService.IsCandidate(Part("logo.png", "image", "png"), "发票"), "Signature image excluded");
        Check(!MailService.IsCandidate(Part("普通图片.jpg", "image", "jpeg", false), "发票"), "Unlabelled inline photo excluded");
        Check(MailService.IsCandidate(Part("电子发票.png", "image", "png", false), "发票"), "Named inline invoice accepted as candidate");
        Check(MailService.IsCandidate(Part("发票及行程单.zip", "application", "zip"), "发票"), "ZIP bundle inspected after download");
        Check(!MailService.IsCandidate(Part("发票.exe", "application", "octet-stream"), "发票"), "Executable attachment rejected");
        Check(MailService.MessageId("a@qq.com", 9, 42) != MailService.MessageId("b@qq.com", 9, 42), "Accounts isolated");
        Check(MailService.MessageId("a@qq.com", 9, 42) != MailService.MessageId("a@qq.com", 10, 42), "UIDVALIDITY isolated");
        Console.WriteLine("邮箱附件元数据与设置验证检查通过；未访问真实邮箱、密钥或注册表");
    }
    private static BodyPartBasic Part(string filename, string type, string subtype, bool attachment = true)
    {
        var content = new ContentType(type, subtype) { Name = filename };
        return new BodyPartBasic(content, "2")
        {
            ContentDisposition = new ContentDisposition(attachment ? ContentDisposition.Attachment : ContentDisposition.Inline) { FileName = filename }
        };
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static void Reject(Action action)
    {
        try { action(); }
        catch (InvalidOperationException) { return; }
        throw new InvalidOperationException("Expected invalid settings to be rejected");
    }
}
