namespace ReimburseApp;

// These checks never load application settings or real secrets; no code accesses this location.
internal static class AppPaths
{
    public static string Root => Path.Combine(Path.GetTempPath(), "reimbursement-offline-settings-check-unused");
}
