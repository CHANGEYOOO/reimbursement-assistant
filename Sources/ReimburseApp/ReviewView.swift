import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let expenseRowType = UTType(exportedAs: "top.kjoe.reimburse.expense-row")

public struct ReviewView: View {
    @StateObject private var store = ExpenseStore()
    @StateObject private var controls = ReviewControls()
    @StateObject private var selection = ReviewSelection()

    public init() {}

    private var blocker: String? {
        if controls.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写报销单标题。" }
        return store.exportBlocker
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    TextField("报销单标题", text: $controls.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Button("导入截图") { chooseImages() }
                    Button("导出 Excel") { saveWorkbook() }
                        .disabled(blocker != nil)
                    Spacer()
                }
                .padding(.horizontal)

                HStack(spacing: 0) {
                    header("序号", width: 64)
                    header("日期", width: 128)
                    header("名称", width: nil)
                    header("图片", width: 160)
                    header("金额", width: 160)
                }
                .padding(.horizontal)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($store.expenses) { $expense in
                            ExpenseRow(expense: $expense, store: store,
                                showPreview: { controls.previewURL = expense.sourceURL },
                                delete: {
                                    if selection.selectedID == expense.id { selection.selectedID = nil }
                                    store.delete(expense.id)
                                })
                                .contentShape(Rectangle())
                                .background(selection.selectedID == expense.id ? Color.blue.opacity(0.18) : Color.clear)
                                .simultaneousGesture(TapGesture().onEnded { selection.selectedID = expense.id })
                                .onDrag {
                                    selection.selectedID = expense.id
                                    let provider = NSItemProvider()
                                    let rowID = Data(expense.id.uuidString.utf8)
                                    provider.registerDataRepresentation(forTypeIdentifier: expenseRowType.identifier,
                                                                        visibility: .ownProcess) { completion in
                                        completion(rowID, nil)
                                        return nil
                                    }
                                    return provider
                                }
                                .onDrop(of: [expenseRowType, .fileURL], isTargeted: nil) { providers in
                                    if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                                        return importDroppedImages(providers)
                                    }
                                    guard let provider = providers.first(where: {
                                        $0.hasItemConformingToTypeIdentifier(expenseRowType.identifier)
                                    }) else { return false }
                                    let targetID = expense.id
                                    provider.loadDataRepresentation(forTypeIdentifier: expenseRowType.identifier) { data, _ in
                                        guard let data, let value = String(data: data, encoding: .utf8),
                                              let sourceID = UUID(uuidString: value) else { return }
                                        Task { @MainActor in
                                            store.move(sourceID, to: targetID)
                                            selection.selectedID = sourceID
                                        }
                                    }
                                    return true
                                }
                            Divider()
                        }
                    }
                }
                .background(.background)

                HStack {
                    Text("已导入 \(store.expenses.count) 张 · 有效 \(store.exportExpenses.count) 笔 · 待核对 \(store.reviewCount) 笔 · 合计 ¥\(currency(store.total))")
                    Spacer()
                    if let blocker { Text(blocker).foregroundStyle(.orange) }
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            if let previewURL = controls.previewURL {
                ImagePreview(url: previewURL) { controls.previewURL = nil }
            }
        }
        .frame(minWidth: 1020, minHeight: 570)
        .overlay {
            if controls.isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.blue, lineWidth: 3)
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $controls.isDropTarget, perform: importDroppedImages)
        .alert("操作未完成", isPresented: Binding(
            get: { controls.errorMessage != nil },
            set: { if !$0 { controls.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { controls.errorMessage = nil }
        } message: {
            Text(controls.errorMessage ?? "")
        }
    }

    private func header(_ text: String, width: CGFloat?) -> some View {
        Text(text).font(.headline)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { store.importFiles(panel.urls) }
    }

    private func importDroppedImages(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in files {
                if let url = await droppedURL(from: provider), url.isFileURL,
                   ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()) {
                    urls.append(url)
                }
            }
            if urls.isEmpty { controls.errorMessage = "请从文件夹拖入 PNG、JPEG 或 HEIC 图片。" }
            else { store.importFiles(urls) }
        }
        return true
    }

    private func droppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else { continuation.resume(returning: nil) }
            }
        }
    }

    private func saveWorkbook() {
        guard blocker == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")!]
        panel.nameFieldStringValue = controls.title + ".xlsx"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                controls.errorMessage = "保存位置是符号链接，请改名或选择真实文件。"
                return
            }
            try WorkbookWriter.write(title: controls.title, expenses: store.exportExpenses, to: destination,
                overwriteConfirmed: FileManager.default.fileExists(atPath: destination.path))
        } catch {
            controls.errorMessage = error.localizedDescription
        }
    }
}

@MainActor private final class ReviewControls: ObservableObject {
    @Published var title = "报销单"
    @Published var previewURL: URL?
    @Published var errorMessage: String?
    @Published var isDropTarget = false
}

@MainActor private final class ReviewSelection: ObservableObject {
    @Published var selectedID: UUID?
}

private struct ExpenseRow: View {
    @Binding var expense: Expense
    @ObservedObject var store: ExpenseStore
    let showPreview: () -> Void
    let delete: () -> Void
    @StateObject private var amountDraft = AmountDraft()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(expense.number)")
                HStack(spacing: 2) {
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .help("删除第\(expense.number)笔记录")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }.frame(width: 64, alignment: .leading)
            TextField("年-月-日", text: Binding(
                get: { expense.date },
                set: { value in
                    store.markEdited(expense.id, field: .date)
                    expense.date = value
                }
            ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 118)
                .padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 5) {
                TextField("填写用途", text: Binding(
                    get: { expense.purpose },
                    set: { value in
                        store.markEdited(expense.id, field: .purpose)
                        expense.purpose = value
                    }
                ))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("分类", selection: Binding(
                        get: { expense.category },
                        set: { value in store.selectCategory(value, for: expense.id) }
                    )) {
                        ForEach(ExpenseCategory.allCases, id: \.self) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Text(expense.sourceURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if store.pendingIDs.contains(expense.id) { ProgressView("正在识别") }
                if let warning = expense.warning, !store.pendingIDs.contains(expense.id) {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                    if !expense.isDuplicate {
                        Toggle("已人工核对", isOn: Binding(
                            get: { store.confirmedWarnings.contains(expense.id) },
                            set: { checked in
                                if checked { store.confirmedWarnings.insert(expense.id) }
                                else { store.confirmedWarnings.remove(expense.id) }
                            }
                        ))
                        .font(.caption)
                    }
                }
                if let text = store.recognizedTexts[expense.id], !text.isEmpty {
                    DisclosureGroup("识别文字") {
                        Text(text).font(.caption).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: showPreview) {
                if let image = NSImage(contentsOf: expense.sourceURL) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: 148, height: 108)
                } else {
                    Text("无法预览").frame(width: 148, height: 108)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 160)
            .accessibilityLabel("放大第\(expense.number)张截图")
            VStack(alignment: .leading, spacing: 5) {
                TextField("金额", text: Binding(
                    get: { amountDraft.text },
                    set: { value in
                        amountDraft.edited = true
                        amountDraft.text = value
                        store.markEdited(expense.id, field: .amount)
                        expense.amount = ExpenseStore.parseAmountInput(value)
                    }
                ))
                    .textFieldStyle(.roundedBorder)
                    .onAppear { syncAmountDraft() }
                    .onChange(of: expense.amount) { _, _ in syncAmountDraft() }
                if let candidates = store.amountCandidates[expense.id], !candidates.isEmpty {
                    Text("点击选择金额").font(.caption).foregroundStyle(.secondary)
                    ForEach(candidates, id: \.self) { candidate in
                        Button {
                            store.selectAmountCandidate(candidate, for: expense.id)
                            amountDraft.text = "\(candidate.amount)"
                            amountDraft.edited = false
                        } label: {
                            Text(verbatim: "\(expense.amount == candidate.amount ? "✓ " : "")¥\(candidate.amount)")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(candidate.source)
                        .disabled(expense.isDuplicate)
                    }
                }
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .opacity(expense.isDuplicate ? 0.6 : 1)
    }

    private func syncAmountDraft() {
        if !amountDraft.edited { amountDraft.text = expense.amount.map { "\($0)" } ?? "" }
    }
}

@MainActor private final class AmountDraft: ObservableObject {
    @Published var text = ""
    var edited = false
}

private func currency(_ amount: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: amount as NSDecimalNumber) ?? "0.00"
}
