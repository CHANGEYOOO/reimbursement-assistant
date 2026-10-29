using System.Text.RegularExpressions;

namespace ReimburseApp;

internal static class GitHubReleaseRules
{
    internal static Version ParseVersion(string value)
    {
        var match = Regex.Match(value, @"\d+(?:\.\d+){1,3}");
        return match.Success && Version.TryParse(match.Value, out var version) ? version : throw new InvalidDataException("发布版本号无法读取。");
    }
    internal static Uri DownloadUri(string? value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host != "github.com" || uri.UserInfo.Length > 0 || !uri.AbsolutePath.StartsWith("/CHANGEYOOO/reimbursement-assistant/releases/", StringComparison.Ordinal)) throw new InvalidDataException("下载地址不属于当前项目。");
        return uri;
    }
}
