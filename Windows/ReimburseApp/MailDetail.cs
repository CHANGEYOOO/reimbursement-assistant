using System.Net;
using System.Text.RegularExpressions;

namespace ReimburseApp;

public sealed record MailDetail(string Body, IReadOnlyList<Uri> Links)
{
    public static MailDetail FromText(string raw, bool html)
    {
        if (html) raw = Regex.Replace(raw, @"<(script|style)\b[^>]*>[\s\S]*?</\1\s*>", "", RegexOptions.IgnoreCase);
        var links = Regex.Matches(raw, @"https?://[^\s<>""']+", RegexOptions.IgnoreCase).Select(m => WebUtility.HtmlDecode(m.Value))
            .Select(s => Uri.TryCreate(s, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http" && string.IsNullOrEmpty(uri.UserInfo) ? uri : null)
            .OfType<Uri>().DistinctBy(u => u.AbsoluteUri).Take(30).ToList();
        var body = raw;
        if (html)
        {
            body = Regex.Replace(body, @"<(script|style)\b[^>]*>[\s\S]*?</\1\s*>", "", RegexOptions.IgnoreCase);
            body = Regex.Replace(body, @"<\s*(?:br|/p|/div|/tr)\b[^>]*>", "\n", RegexOptions.IgnoreCase);
            body = WebUtility.HtmlDecode(Regex.Replace(body, "<[^>]+>", ""));
        }
        return new(body, links);
    }
}

