namespace ReimburseApp;

// This executable never loads real application settings or stored credentials.
internal sealed class AppSettings
{
    public static AppSettings Current { get; } = new();
    public bool AiEnabled { get; set; }
    public string AiEndpoint { get; set; } = "https://example.invalid/chat/completions";
    public string AiModel { get; set; } = "test-model";
    public string ApiKey { get; set; } = "offline-test";
}
