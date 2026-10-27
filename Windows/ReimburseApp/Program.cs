using System.Reflection;
using System.Windows.Forms;
using Tesseract;

namespace ReimburseApp;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        var selfCheck = Environment.GetCommandLineArgs().Contains("--self-check");
        if (selfCheck) AppPaths.UseTestRoot(Path.Combine(Path.GetTempPath(), "reimburse-windows-check-" + Guid.NewGuid()));
        var appDirectory = Path.Combine(AppPaths.Root, "ocr-5.2.0");
        var dataDirectory = Path.Combine(appDirectory, "tessdata");
        Directory.CreateDirectory(dataDirectory);
        var nativeDirectory = Path.Combine(appDirectory, "x64");
        Directory.CreateDirectory(nativeDirectory);
        foreach (var library in new[] { "leptonica-1.82.0.dll", "tesseract50.dll" })
            Extract($"ReimburseApp.native.x64.{library}", Path.Combine(nativeDirectory, library));
        foreach (var language in new[] { "chi_sim", "eng" })
        {
            var destination = Path.Combine(dataDirectory, language + ".traineddata");
            Extract($"ReimburseApp.tessdata.{language}.traineddata", destination);
        }
        TesseractEnviornment.CustomSearchPath = appDirectory;
        if (selfCheck)
        {
            try { using var form = new MainForm(dataDirectory); form.SelfCheck(); File.WriteAllText("build/windows-smoke.log", "Windows startup, native OCR, autosave, manual amount and Excel checks passed"); }
            catch (Exception ex) { File.WriteAllText("build/windows-smoke.log", ex.ToString()); Environment.ExitCode = 1; }
            return;
        }
        try { Application.Run(new MainForm(dataDirectory)); }
        catch (Exception ex) { MessageBox.Show("启动失败，资料已保留：" + ex.Message, "报销单助手", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    private static void Extract(string resourceName, string destination)
    {
        if (File.Exists(destination)) return;
        using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"缺少程序资源：{resourceName}");
        using var output = File.Create(destination);
        source.CopyTo(output);
    }
}
