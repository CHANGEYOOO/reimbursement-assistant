import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let expenseRowType = UTType(exportedAs: "top.kjoe.reimburse.expense-row")

public struct ReviewView: View {
    @StateObject private var store = ExpenseStore()
    @StateObject private var invoices = InvoiceStore()
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
                    Button("新建报销单") { createDraft() }
                    Button("打开报销单") { openDraftPicker() }
                    Text(controls.saveStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    Picker("区域", selection: $controls.showingInvoices) {
                        Text("订单截图").tag(false)
                        Text("发票夹").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    if controls.showingInvoices {
                        Button("导入发票") { chooseInvoices() }
                        Button(controls.exportingInvoices ? "正在导出…" : "导出发票文件夹") { exportInvoices() }
                            .disabled(invoices.invoices.isEmpty || controls.exportingInvoices || !invoices.pendingIDs.isEmpty)
                        TextField("识别不到时填写购买方抬头", text: Binding(
                            get: { invoices.companyTitleFallback },
                            set: { invoices.updateCompanyTitleFallback($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        Text(controls.exportStatus).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("导入截图") { chooseImages() }
                        Button("全部标记已人工核对") { store.confirmAll() }
                            .disabled(store.expenses.isEmpty || !store.pendingIDs.isEmpty)
                        Button("导出 Excel") { saveWorkbook() }
                            .disabled(blocker != nil)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                if !controls.showingInvoices {
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
                } else {
                    invoiceList
                }

                HStack {
                    if controls.showingInvoices {
                        Text("发票 \(invoices.invoices.count) 张 · 发票合计 ¥\(currency(invoices.total)) · 订单合计 ¥\(currency(store.amountTotal))")
                        let difference = store.amountTotal - invoices.total
                        if store.amountTotal == 0 {
                            Text("请先录入订单金额").foregroundStyle(.secondary)
                        } else {
                            Text(difference > 0 ? "还差 ¥\(currency(difference))" : "发票金额已足额")
                                .foregroundStyle(difference > 0 ? .orange : .green)
                        }
                    } else {
                        Text("已导入 \(store.expenses.count) 张 · 有效 \(store.exportExpenses.count) 笔 · 待核对 \(store.reviewCount) 笔 · 合计 ¥\(currency(store.total))")
                    }
                    Spacer()
                    if !controls.showingInvoices, let blocker { Text(blocker).foregroundStyle(.orange) }
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
        .onAppear(perform: restoreDraft)
        .onChange(of: controls.title) { _, _ in scheduleSave() }
        .onReceive(store.objectWillChange) { _ in scheduleSave() }
        .onChange(of: invoices.lastError) { _, error in
            if let error { controls.errorMessage = error }
        }
        .sheet(isPresented: $controls.showingDrafts) {
            VStack(alignment: .leading, spacing: 12) {
                Text("打开报销单").font(.title2)
                List(controls.availableDrafts) { item in
                    Button {
                        openDraft(item)
                        controls.showingDrafts = false
                    } label: {
                        HStack {
                            Text(item.title)
                            Spacer()
                            Text(item.updatedAt, style: .date).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button("取消") { controls.showingDrafts = false }
            }
            .padding()
            .frame(width: 440, height: 320)
        }
        .alert("操作未完成", isPresented: Binding(
            get: { controls.errorMessage != nil },
            set: { if !$0 { controls.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { controls.errorMessage = nil }
        } message: {
            Text(controls.errorMessage ?? "")
        }
    }

    private var invoiceList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(invoices.invoices) { invoice in
                    InvoiceRow(invoice: invoice, store: invoices,
                               preview: { url in
                                   if url.pathExtension.lowercased() == "pdf" { NSWorkspace.shared.open(url) }
                                   else { controls.previewURL = url }
                               },
                               reportError: { controls.errorMessage = $0 })
                    Divider()
                }
            }
        }
    }

    private func header(_ text: String, width: CGFloat?) -> some View {
        Text(text).font(.headline)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func restoreDraft() {
        guard controls.draft == nil else { return }
        do {
            let drafts = try DraftStorage.list()
            if let id = DraftStorage.lastOpened(), let existing = drafts.first(where: { $0.id == id }) {
                openDraft(existing)
            } else {
                let created = try DraftStorage.create(title: controls.title)
                controls.draft = created
                invoices.configure(directory: created.url)
                controls.saveStatus = "已保存"
            }
        } catch { controls.errorMessage = "无法打开草稿：\(error.localizedDescription)" }
    }

    private func scheduleSave() {
        guard controls.draft != nil else { return }
        controls.saveTask?.cancel()
        controls.saveStatus = "正在保存…"
        controls.saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            saveCurrent()
        }
    }

    private func saveCurrent() {
        guard let draft = controls.draft else { return }
        do {
            controls.draft = try DraftStorage.save(store, title: controls.title, draft: draft)
            controls.saveStatus = "已保存"
        } catch {
            controls.saveStatus = "保存失败"
            controls.errorMessage = "草稿保存失败：\(error.localizedDescription)"
        }
    }

    private func createDraft() {
        controls.saveTask?.cancel()
        saveCurrent()
        guard controls.saveStatus != "保存失败" else { return }
        do {
            let created = try DraftStorage.create(title: "报销单")
            controls.draft = created
            store.reset()
            invoices.configure(directory: created.url)
            controls.title = created.title
            controls.saveStatus = "已保存"
            controls.showingInvoices = false
        } catch { controls.errorMessage = "新建报销单失败：\(error.localizedDescription)" }
    }

    private func openDraftPicker() {
        controls.saveTask?.cancel()
        saveCurrent()
        guard controls.saveStatus != "保存失败" else { return }
        do {
            controls.availableDrafts = try DraftStorage.list()
            controls.showingDrafts = true
        } catch { controls.errorMessage = "读取草稿失败：\(error.localizedDescription)" }
    }

    private func openDraft(_ selected: DraftSummary) {
        controls.saveTask?.cancel()
        do {
            let opened = try DraftStorage.open(selected, into: store)
            controls.draft = opened
            invoices.configure(directory: opened.url)
            controls.title = opened.title
            controls.saveStatus = "已保存"
            controls.showingInvoices = false
        } catch { controls.errorMessage = "打开草稿失败：\(error.localizedDescription)" }
    }

    private func chooseInvoices() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .pdf, .zip]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { invoices.importFiles(panel.urls) }
    }

    private func exportInvoices() {
        let panel = NSOpenPanel()
        panel.prompt = "导出到此处"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        controls.exportingInvoices = true
        controls.exportStatus = ""
        Task {
            do {
                let folders = try await invoices.exportGrouped(to: parent)
                controls.exportStatus = "已导出 \(folders.count) 个文件夹"
                NSWorkspace.shared.open(folders.count == 1 ? folders[0] : parent)
            } catch { controls.errorMessage = "导出发票失败：\(error.localizedDescription)" }
            controls.exportingInvoices = false
        }
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
                   (controls.showingInvoices ? ["png", "jpg", "jpeg", "heic", "heif", "pdf", "zip"] : ["png", "jpg", "jpeg", "heic"]).contains(url.pathExtension.lowercased()) {
                    urls.append(url)
                }
            }
            if urls.isEmpty { controls.errorMessage = controls.showingInvoices ? "请拖入发票图片、PDF 或 ZIP 压缩包。" : "请从文件夹拖入 PNG、JPEG 或 HEIC 图片。" }
            else if controls.showingInvoices { invoices.importFiles(urls) }
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

private struct InvoiceRow: View {
    let invoice: Invoice
    @ObservedObject var store: InvoiceStore
    let preview: (URL) -> Void
    let reportError: (String) -> Void
    @StateObject private var amountDraft = AmountDraft()

    var body: some View {
        HStack(spacing: 12) {
            Button(invoice.originalFilename) { preview(store.sourceURL(for: invoice)) }
                .frame(maxWidth: .infinity, alignment: .leading)
            if store.pendingIDs.contains(invoice.id) { ProgressView() }
            TextField("价税合计", text: Binding(
                get: { amountDraft.text },
                set: { value in
                    amountDraft.edited = true
                    amountDraft.text = value
                    store.updateAmount(value, for: invoice.id)
                }
            ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            if let warning = invoice.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            Button("删除") {
                do { try store.delete(invoice.id) }
                catch { reportError(error.localizedDescription) }
            }
        }
        .padding(.horizontal)
        .onAppear { amountDraft.text = invoice.amount.map { "\($0)" } ?? "" }
        .onChange(of: invoice.amount) { _, value in
            guard !amountDraft.edited else { return }
            amountDraft.text = value.map { "\($0)" } ?? ""
        }
    }
}

@MainActor private final class ReviewControls: ObservableObject {
    @Published var title = "报销单"
    @Published var previewURL: URL?
    @Published var errorMessage: String?
    @Published var isDropTarget = false
    @Published var draft: DraftSummary?
    @Published var availableDrafts: [DraftSummary] = []
    @Published var showingDrafts = false
    @Published var showingInvoices = false
    @Published var saveStatus = ""
    @Published var exportingInvoices = false
    @Published var exportStatus = ""
    var saveTask: Task<Void, Never>?
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
            LiveDateField(text: Binding(
                get: { expense.date },
                set: { value in
                    store.markEdited(expense.id, field: .date)
                    expense.date = value
                }
            ))
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
                }
                if !expense.isDuplicate && !store.pendingIDs.contains(expense.id) {
                    Toggle("已人工核对", isOn: Binding(
                        get: { store.confirmedWarnings.contains(expense.id) },
                        set: { checked in
                            if checked { store.confirmedWarnings.insert(expense.id) }
                            else { store.confirmedWarnings.remove(expense.id) }
                        }
                    ))
                    .font(.caption)
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

private struct LiveDateField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "年-月-日"
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LiveDateField

        init(_ parent: LiveDateField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() else { return }
            let formatted = ExpenseDate.formattedInput(editor.string, previous: parent.text)
            if editor.string != formatted {
                editor.string = formatted
                editor.selectedRange = NSRange(location: formatted.utf16.count, length: 0)
            }
            parent.text = formatted
        }
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
