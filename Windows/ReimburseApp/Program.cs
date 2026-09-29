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
        var appDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "报销单助手", "ocr-5.2.0");
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
        Application.Run(new MainForm(dataDirectory));
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
