namespace ReimburseApp;

public sealed class ExpenseRow
{
    public Guid Id { get; } = Guid.NewGuid();
    public string ImagePath { get; init; } = "";
    public string Fingerprint { get; init; } = "";
    public string Date { get; set; } = "";
    public string Purpose { get; set; } = "";
    public string Category { get; set; } = "待分类";
    public decimal? Amount { get; set; }
    public string? Warning { get; set; }
    public string RecognizedText { get; set; } = "";
    internal IReadOnlyList<AmountCandidate> AmountCandidates { get; set; } = [];
    public bool Confirmed { get; set; }
    public bool Duplicate { get; set; }
    public bool Pending { get; set; }
}
