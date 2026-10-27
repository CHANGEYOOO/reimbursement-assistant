using System.Globalization;
using System.Text.Json.Serialization;

namespace ReimburseApp;

public sealed class ExpenseRow
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string ImagePath { get; set; } = "";
    public string OriginalFilename { get; set; } = "";
    public string Fingerprint { get; set; } = "";
    public string Date { get; set; } = "";
    public string Purpose { get; set; } = "";
    public string Category { get; set; } = "待分类";
    public decimal? Amount { get; set; }
    public string? Warning { get; set; }
    public string RecognizedText { get; set; } = "";
    public IReadOnlyList<AmountCandidate> AmountCandidates { get; set; } = [];
    public bool Confirmed { get; set; }
    public bool Duplicate { get; set; }
    public bool Pending { get; set; }
    public bool AiRecognized { get; set; }
    public string? AiNote { get; set; }
    public HashSet<string> Edited { get; set; } = [];

    [JsonIgnore] public IReadOnlyList<string> Issues
    {
        get
        {
            if (Duplicate) return [];
            var issues = new List<string>();
            if (Pending) issues.Add("正在识别，请等待完成");
            if (Amount is not > 0) issues.Add("请填写正数金额");
            if (!Recognition.IsValidDate(Date)) issues.Add("请填写有效日期（年-月-日）");
            if (string.IsNullOrWhiteSpace(Purpose)) issues.Add("请填写用途");
            if (Warning != null && !Confirmed && !Pending) issues.Add(Warning + "；请人工核对");
            return issues;
        }
    }
    [JsonIgnore] public string Status => Duplicate ? "重复截图" : Pending ? "识别中" : Issues.Count > 0 ? "待处理" : Confirmed ? "已核对" : AiRecognized ? "AI 已识别" : "可导出";
}
