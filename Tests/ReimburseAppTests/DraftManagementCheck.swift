#if DIRECT_TEST_RUNNER
import Foundation

@main struct DraftManagementCheck {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-management-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expense = Expense(number: 1, sourceURL: directory.appendingPathComponent("image.png"),
                              amount: 39, purpose: "餐食费用", date: "2026-10-25")
        let snapshot = DraftSnapshot(title: "原名", updatedAt: .distantPast, expenses: [expense],
            pendingIDs: [], confirmedWarnings: [expense.id], recognizedTexts: [:], amountCandidates: [:])
        let metadata = directory.appendingPathComponent("draft.json")
        try JSONEncoder().encode(snapshot).write(to: metadata)
        let original = DraftSummary(id: UUID(), title: "原名", updatedAt: .distantPast, url: directory)
        let renamed = try DraftStorage.rename(original, to: "  新名称  ")
        let restored = try JSONDecoder().decode(DraftSnapshot.self, from: Data(contentsOf: metadata))
        precondition(renamed.id == original.id && renamed.url == original.url && renamed.title == "新名称")
        precondition(restored.title == "新名称" && restored.expenses[0].id == expense.id)
        precondition(restored.expenses[0].amount == 39 && restored.confirmedWarnings.contains(expense.id))
        do {
            _ = try DraftStorage.rename(renamed, to: " \n ")
            preconditionFailure("Blank title must be rejected")
        } catch { }
        do {
            try DraftStorage.moveToTrash(renamed)
            preconditionFailure("A folder outside the drafts directory must not be trashed")
        } catch { }
        precondition(FileManager.default.fileExists(atPath: metadata.path))
        print("Draft management checks passed; temporary data retained at \(directory.path)")
    }
}
#endif
