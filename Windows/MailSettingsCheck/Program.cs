using MailKit;
using MimeKit;
using ReimburseApp;
using MailService = ReimburseApp.MailService;

MailSettingsChecks.Run();

internal static class MailSettingsChecks
{
    internal static void Run()
    {
        var detail = MailDetail.FromText("<script>location='https://bad.test'</script><p>正文</p><img src='https://image.test/p'><a href='https://example.com/file'>下载</a>", true);
        Check(detail.Body.Contains("正文") && !detail.Body.Contains("<") && !detail.Body.Contains("location="), "HTML is displayed only as inert plain text");
        Check(detail.Links.All(u => u.Scheme is "http" or "https") && !detail.Links.Any(u => u.Host == "bad.test"), "Only explicit safe web links are offered");
        AppSettings.ValidateAi("https://api.deepseek.com/chat/completions", "deepseek-flash", "test-key");
        foreach (var endpoint in new[] { "http://example.com/api", "https://user:pass@example.com/api", "https://example.com/api?token=x", "https://example.com/api#fragment", "relative/path" })
            Reject(() => AppSettings.ValidateAi(endpoint, "model", "key"));
        Reject(() => AppSettings.ValidateAi("https://example.com/api", "two words", "key"));
        Reject(() => AppSettings.ValidateAi("https://example.com/api", "model", "bad\nkey"));
        var mailbox = new AppSettings { MailEnabled = true, MailAddress = "one@qq.com", MailPassword = "fake-authorization" };
        var unrelated = mailbox.Copy(); unrelated.NotificationsEnabled = true; unrelated.CacheLimitMb = 500; unrelated.AiEnabled = true;
        Check(mailbox.SameMailbox(unrelated), "Notification, AI and cache settings must not interrupt mail sync");
        unrelated.MailAddress = "two@qq.com";
        Check(!mailbox.SameMailbox(unrelated), "Changing QQ account invalidates the old sync");
        var profiles = new AppSettings { AiEndpoint = "https://deepseek.example.invalid/chat/completions", AiModel = "saved-deepseek", ApiKey = "fake-deepseek-secret" };
        profiles.CaptureAiProfile();
        profiles.SelectAiProvider("阿里百炼");
        Check(profiles.AiModel == "qwen-plus" && profiles.ApiKey == "", "New provider starts with its own defaults and no inherited key");
        profiles.AiEndpoint = "https://aliyun.example.invalid/chat/completions"; profiles.AiModel = "saved-aliyun"; profiles.ApiKey = "fake-aliyun-secret";
        profiles.SelectAiProvider("DeepSeek");
        Check(profiles.AiEndpoint == "https://deepseek.example.invalid/chat/completions" && profiles.AiModel == "saved-deepseek" && profiles.ApiKey == "fake-deepseek-secret", "DeepSeek profile and key restored");
        profiles.SelectAiProvider("阿里百炼");
        Check(profiles.AiModel == "saved-aliyun" && profiles.ApiKey == "fake-aliyun-secret", "Aliyun profile and key restored");
        profiles.InvoiceFallbackEnabled = true;
        var copied = profiles.Copy();
        Check(copied.InvoiceFallbackEnabled && !new AppSettings().InvoiceFallbackEnabled, "Invoice AI consent is independent, copied and off by default");
        copied.AiProfiles["DeepSeek"] = new AiProfile("https://copy.example.invalid/api", "copied");
        copied.ApiKeys["DeepSeek"] = "fake-copy-secret";
        Check(profiles.AiProfiles["DeepSeek"].Model == "saved-deepseek" && profiles.ApiKeys["DeepSeek"] == "fake-deepseek-secret", "Profile dictionaries copied independently");
        copied.SelectAiProvider("自定义");
        Check(copied.AiEndpoint == "" && copied.ApiKey == "", "Custom provider cannot inherit another provider key");
        var plainJson = System.Text.Json.JsonSerializer.Serialize(profiles);
        Check(!plainJson.Contains("fake-deepseek-secret") && !plainJson.Contains("fake-aliyun-secret") && !plainJson.Contains("ApiKeys") && !plainJson.Contains("ApiKey"), "All active and inactive API keys excluded from plain settings JSON");
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
        Check(MailService.IsCandidate(Part("行程单.pdf", "application", "pdf"), "您的发票"), "Invoice email attachments are classified by content after download");
        Check(MailService.IsCandidate(Part("发票报销单.pdf", "application", "pdf"), "发票"), "Report filename alone cannot decide attachment type");
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
