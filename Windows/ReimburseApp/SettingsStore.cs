using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ReimburseApp;

public sealed class AppSettings
{
    private static AppSettings? _current;
    internal static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    public static AppSettings Current => _current ??= Load();
    public static int Revision { get; private set; }
    public bool AiEnabled { get; set; }
    public string AiProvider { get; set; } = "DeepSeek";
    public string AiEndpoint { get; set; } = "https://api.deepseek.com/chat/completions";
    public string AiModel { get; set; } = "deepseek-flash";
    [JsonIgnore] public string ApiKey { get; set; } = "";
    public bool MailEnabled { get; set; }
    public string MailAddress { get; set; } = "";
    [JsonIgnore] public string MailPassword { get; set; } = "";
    public DateTimeOffset MailSince { get; set; } = new(DateTime.Today.AddDays(-30));
    public bool NotificationsEnabled { get; set; }
    public bool StartupEnabled { get; set; }
    public double CacheLimitMb { get; set; } = 200;

    public AppSettings Copy() => new()
    {
        AiEnabled = AiEnabled, AiProvider = AiProvider, AiEndpoint = AiEndpoint, AiModel = AiModel, ApiKey = ApiKey,
        MailEnabled = MailEnabled, MailAddress = MailAddress, MailPassword = MailPassword, MailSince = MailSince,
        NotificationsEnabled = NotificationsEnabled, StartupEnabled = StartupEnabled, CacheLimitMb = CacheLimitMb
    };

    public static void Save() => Replace(Current);

    public static void Replace(AppSettings settings)
    {
        Validate(settings);
        var secrets = JsonSerializer.SerializeToUtf8Bytes(new SecretValues(settings.ApiKey, settings.MailAddress, settings.MailPassword));
        string protectedSecrets;
        try { protectedSecrets = Convert.ToBase64String(ProtectedData.Protect(secrets, null, DataProtectionScope.CurrentUser)); }
        catch (Exception ex) when (ex is CryptographicException or PlatformNotSupportedException)
        { throw new InvalidOperationException("无法使用 Windows 系统加密保存密钥，设置未保存。", ex); }
        finally { CryptographicOperations.ZeroMemory(secrets); }
        WriteJson(Path.Combine(AppPaths.Root, "settings.json"), new SettingsDocument { Settings = settings, ProtectedSecrets = protectedSecrets });
        _current = settings.Copy();
        Revision++;
    }

    public static void Validate(AppSettings settings)
    {
        if (!double.IsFinite(settings.CacheLimitMb) || settings.CacheLimitMb <= 0 || settings.CacheLimitMb > 1_000_000)
            throw new InvalidOperationException("请填写大于 0、且不超过 1000000 MB 的缓存上限。");
        if (settings.MailSince.Date > DateTime.Today) throw new InvalidOperationException("收集日期不能晚于今天。");
        if (settings.AiEnabled) ValidateAi(settings.AiEndpoint, settings.AiModel, settings.ApiKey);
        if (settings.MailEnabled || !string.IsNullOrWhiteSpace(settings.MailAddress))
            MailService.ValidateCredentials(settings.MailAddress, settings.MailEnabled ? settings.MailPassword : "validation");
    }

    public static void ValidateAi(string endpoint, string model, string key)
    {
        if (!Uri.TryCreate(endpoint.Trim(), UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttps ||
            string.IsNullOrWhiteSpace(url.Host) || !string.IsNullOrEmpty(url.UserInfo) || !string.IsNullOrEmpty(url.Query) || !string.IsNullOrEmpty(url.Fragment))
            throw new InvalidOperationException("请填写完整的 HTTPS 接口地址，不要包含账号、密码、查询参数或片段。");
        if (string.IsNullOrWhiteSpace(model) || model.Length > 200 || model.Any(char.IsWhiteSpace))
            throw new InvalidOperationException("请填写有效的模型名称。");
        if (string.IsNullOrWhiteSpace(key) || key.Any(char.IsControl)) throw new InvalidOperationException("请填写有效的 API Key。");
    }

    internal static void WriteJson<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value, JsonOptions), Encoding.UTF8);
        File.Move(temporary, path, true);
    }

    private static AppSettings Load()
    {
        var path = Path.Combine(AppPaths.Root, "settings.json");
        if (!File.Exists(path)) return new AppSettings();
        try
        {
            var document = JsonSerializer.Deserialize<SettingsDocument>(File.ReadAllText(path), JsonOptions)
                ?? throw new InvalidDataException();
            if (document.Version != 1 || document.Settings == null) throw new InvalidDataException();
            var settings = document.Settings;
            if (!string.IsNullOrEmpty(document.ProtectedSecrets))
            {
                var plain = ProtectedData.Unprotect(Convert.FromBase64String(document.ProtectedSecrets), null, DataProtectionScope.CurrentUser);
                try
                {
                    var secrets = JsonSerializer.Deserialize<SecretValues>(plain) ?? throw new InvalidDataException();
                    settings.ApiKey = secrets.ApiKey;
                    if (string.Equals(secrets.MailAddress, settings.MailAddress, StringComparison.OrdinalIgnoreCase)) settings.MailPassword = secrets.MailPassword;
                }
                finally { CryptographicOperations.ZeroMemory(plain); }
            }
            Validate(settings);
            return settings;
        }
        catch (Exception ex) when (ex is IOException or JsonException or CryptographicException or FormatException or PlatformNotSupportedException or InvalidOperationException)
        { throw new InvalidOperationException("无法读取设置或解密密钥。请使用原来的 Windows 用户账户，并检查设置文件权限；原文件已保留。", ex); }
    }

    private sealed class SettingsDocument
    {
        public int Version { get; set; } = 1;
        public AppSettings? Settings { get; set; }
        public string ProtectedSecrets { get; set; } = "";
    }
    private sealed record SecretValues(string ApiKey, string MailAddress, string MailPassword);
}
