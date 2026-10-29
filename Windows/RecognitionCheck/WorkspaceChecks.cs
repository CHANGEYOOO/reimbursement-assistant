using ReimburseApp;

internal static class WorkspaceChecks
{
    internal static void Run()
    {
        AppPaths.UseTestRoot(Path.Combine(Path.GetTempPath(), "reimbursement-project-check-" + Guid.NewGuid()));
        var store = new ProjectStore(); var first = store.Create(); first.Title = "第一个"; store.Save(first);
        var directory = ProjectStore.DirectoryFor(first); var file = Path.Combine(directory, "project.json");
        Directory.SetCreationTimeUtc(directory, DateTime.UtcNow.AddDays(-2));
        var second = store.Create(); second.Title = "第二个"; store.Save(second);
        var bytes = File.ReadAllBytes(file); var timestamp = File.GetLastWriteTimeUtc(file);
        store.Save(first); store.Select(first); store.Save(first);
        Check(bytes.SequenceEqual(File.ReadAllBytes(file)) && timestamp == File.GetLastWriteTimeUtc(file), "Unchanged saves preserve project bytes and modification time");
        first.Title = "第一个已修改"; store.Save(first);
        var reloaded = new ProjectStore();
        Check(reloaded.Projects.Select(p => p.Id).SequenceEqual(new[] { second.Id, first.Id }), "Editing or opening does not reorder creation-sorted projects");
        Check(reloaded.Projects[1].Title == "第一个已修改" && reloaded.LastSelectedId == first.Id, "Real edits and selection persist");
        Check(GitHubReleaseRules.ParseVersion("v1.34.0") > GitHubReleaseRules.ParseVersion("v1.9.0"), "Release versions compare numerically");
        Check(GitHubReleaseRules.DownloadUri("https://github.com/CHANGEYOOO/reimbursement-assistant/releases/tag/v1.34.0").Host == "github.com", "Own release links are accepted");
        foreach (var invalid in new[] { "http://github.com/CHANGEYOOO/reimbursement-assistant/releases/a", "https://github.com.evil.test/CHANGEYOOO/reimbursement-assistant/releases/a", "https://github.com/other/repo/releases/a", "https://user@github.com/CHANGEYOOO/reimbursement-assistant/releases/a" })
        { try { GitHubReleaseRules.DownloadUri(invalid); throw new Exception("Unsafe release URL accepted"); } catch (InvalidDataException) { } }
        Console.WriteLine("Project stable-save/order and GitHub release rules passed");
    }
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
}
