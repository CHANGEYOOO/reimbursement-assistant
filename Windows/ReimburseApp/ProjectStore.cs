using System.Text.Json;
using Microsoft.VisualBasic.FileIO;

namespace ReimburseApp;

public static class AppPaths
{
    public static string Root { get; private set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "报销单助手");
    internal static void UseTestRoot(string path) => Root = path;
    public static string Projects => Path.Combine(Root, "Projects");
    public static string Invoices => Path.Combine(Root, "InvoiceInbox");
}

public sealed class ProjectRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "报销单";
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;
    public List<ExpenseRow> Expenses { get; set; } = [];
    public override string ToString() => Title;
}

public sealed class ProjectStore
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public List<ProjectRecord> Projects { get; } = [];
    public List<string> LoadErrors { get; } = [];
    public ProjectStore()
    {
        Directory.CreateDirectory(AppPaths.Projects);
        foreach (var dir in Directory.EnumerateDirectories(AppPaths.Projects))
        {
            var file = Path.Combine(dir, "project.json");
            if (!File.Exists(file)) continue;
            try { Projects.Add(JsonSerializer.Deserialize<ProjectRecord>(File.ReadAllText(file), Options) ?? throw new InvalidDataException("报销单内容为空")); }
            catch (Exception ex) { LoadErrors.Add(Path.GetFileName(dir) + "：" + ex.Message); }
        }
        Projects.Sort((a, b) => b.UpdatedAt.CompareTo(a.UpdatedAt));
    }
    public Guid? LastSelectedId => File.Exists(Path.Combine(AppPaths.Root, "last-project.txt")) && Guid.TryParse(File.ReadAllText(Path.Combine(AppPaths.Root, "last-project.txt")), out var id) ? id : null;
    public void Select(ProjectRecord project) => AtomicWrite(Path.Combine(AppPaths.Root, "last-project.txt"), project.Id.ToString());
    public ProjectRecord Create()
    {
        var project = new ProjectRecord { Title = "报销单 " + DateTime.Today.ToString("yyyy-MM-dd") };
        Save(project);
        Projects.Insert(0, project);
        return project;
    }
    public static string DirectoryFor(ProjectRecord project) => Path.Combine(AppPaths.Projects, project.Id.ToString());
    public void Save(ProjectRecord project)
    {
        var directory = DirectoryFor(project);
        Directory.CreateDirectory(directory);
        project.UpdatedAt = DateTimeOffset.Now;
        AtomicWrite(Path.Combine(directory, "project.json"), JsonSerializer.Serialize(project, Options));
    }
    public string CopyScreenshot(ProjectRecord project, string source)
    {
        var directory = Path.Combine(DirectoryFor(project), "screenshots");
        Directory.CreateDirectory(directory);
        var target = Path.Combine(directory, Guid.NewGuid() + Path.GetExtension(source).ToLowerInvariant());
        File.Copy(source, target);
        return target;
    }
    public void Delete(ProjectRecord project)
    {
        var directory = DirectoryFor(project);
        if (Directory.Exists(directory)) FileSystem.DeleteDirectory(directory, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin, UICancelOption.ThrowException);
        Projects.Remove(project);
    }
    public static void AtomicWrite(string destination, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var temp = destination + ".new";
        File.WriteAllText(temp, text);
        File.Move(temp, destination, true);
    }
    public static string Snapshot(ProjectRecord project) => JsonSerializer.Serialize(project, Options);
    public static ProjectRecord Restore(string snapshot) => JsonSerializer.Deserialize<ProjectRecord>(snapshot, Options) ?? throw new InvalidDataException("无法撤销此操作");
}
