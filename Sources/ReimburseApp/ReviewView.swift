import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let expenseRowType = UTType(exportedAs: "top.kjoe.reimburse.expense-row")

public struct ReviewView: View {
    @StateObject private var store = ExpenseStore()
    @StateObject private var invoices = InvoiceStore()
    @StateObject private var controls = ReviewControls()
    @StateObject private var selection = ReviewSelection()
    @ObservedObject private var runtime = AppRuntime.shared
    @ObservedObject private var inbox = AppRuntime.shared.inbox
    @ObservedObject private var mailbox = AppRuntime.shared.mailbox

    public init() {}

    private var visibleExpenses: [Binding<Expense>] {
        $store.expenses.filter {
            store.matchesFilters($0.wrappedValue, amountQuery: controls.amountQuery,
                                 onlyNeedsReview: controls.onlyNeedsReview)
        }
    }

    private var blocker: String? {
        if controls.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写报销单标题。" }
        return store.exportBlocker
    }

    public var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 180, idealWidth: 200, maxWidth: 250)
            if controls.showingInbox {
                VStack(spacing: 0) {
                    if !mailbox.manualMessages.isEmpty {
                        DisclosureGroup("\(mailbox.manualMessages.count) 封发票邮件未发现可导入附件") {
                            ForEach(mailbox.manualMessages) { notice in
                                HStack {
                                    Text(notice.subject.isEmpty ? "无主题邮件" : notice.subject).lineLimit(1)
                                    Text(notice.receivedAt, style: .date).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("已手动处理") { mailbox.dismissNotice(notice.id) }
                                }
                            }
                            Text("请在 QQ 邮箱查看这些邮件；可能需要通过邮件内链接下载，再手动导入。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 20).padding(.top, 12)
                    }
                    InvoiceInboxView(inbox: inbox, projects: controls.availableDrafts,
                        targetProject: controls.inboxTarget,
                        sync: { Task { await mailbox.sync(inbox: inbox) } },
                        settings: { controls.showingMailboxSettings = true },
                        syncing: mailbox.syncing, syncStatus: mailbox.status,
                        assigned: {
                            do { try invoices.refreshFromDisk() }
                            catch { controls.errorMessage = error.localizedDescription }
                        })
                }.frame(minWidth: 800, minHeight: 620)
            } else { projectContent }
        }
        .onAppear {
            restoreDraft()
            refreshProjects()
            runtime.saveBeforeExit = {
                controls.saveTask?.cancel()
                saveCurrent()
                return controls.saveStatus != "保存失败"
            }
            if runtime.inboxOpenRequest > 0 { openInbox(target: nil) }
        }
        .onChange(of: runtime.inboxOpenRequest) { _, _ in openInbox(target: nil) }
        .onReceive(store.objectWillChange) { _ in scheduleSave() }
        .onChange(of: invoices.lastError) { _, error in
            if let error { controls.errorMessage = error }
        }
        .onChange(of: controls.draft) { _, _ in refreshProjects() }
        .onChange(of: invoices.invoices.map(\.id)) { _, _ in
            do { try inbox.refreshAssignments() }
            catch { controls.errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $controls.showingMailboxSettings) {
            QQMailboxSettingsView(close: { controls.showingMailboxSettings = false }, saved: {
                mailbox.configurationChanged()
                Task { await mailbox.sync(inbox: inbox) }
            })
        }
        .alert("操作未完成", isPresented: Binding(
            get: { controls.errorMessage != nil },
            set: { if !$0 { controls.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { controls.errorMessage = nil }
        } message: { Text(controls.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("报销单助手").font(.headline).padding(.top, 12)
            Button {
                openInbox(target: nil)
            } label: {
                HStack {
                    Label("发票箱", systemImage: "tray.full")
                    Spacer()
                    Text("\(inbox.items.filter { $0.projectID == nil }.count)").foregroundStyle(.secondary)
                }.padding(8)
                    .background(controls.showingInbox ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
            Divider()
            Text("我的项目").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(controls.availableDrafts) { project in
                        Button {
                            controls.saveTask?.cancel()
                            saveCurrent()
                            guard controls.saveStatus != "保存失败" else { return }
                            openDraft(project)
                            controls.showingInbox = false
                        } label: {
                            Text(project.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(!controls.showingInbox && controls.draft?.id == project.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(controls.exportingInvoices)
                    }
                }
            }
            Button("＋ 新建项目") { createDraft(); refreshProjects() }
                .disabled(controls.exportingInvoices)
            Spacer(minLength: 0)
        }.padding(12)
    }

    private func refreshProjects() {
        do { controls.availableDrafts = try DraftStorage.list() }
        catch { controls.errorMessage = "读取项目列表失败：\(error.localizedDescription)" }
    }

    private func openInbox(target: DraftSummary?) {
        controls.saveTask?.cancel()
        saveCurrent()
        guard controls.saveStatus != "保存失败" else { return }
        do {
            try inbox.refreshAssignments()
            refreshProjects()
            controls.inboxTarget = target
            controls.showingInbox = true
        } catch { controls.errorMessage = error.localizedDescription }
    }

    private var projectContent: some View {
        ZStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("报销单").font(.headline)
                    TextField("报销单标题", text: $controls.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Text(controls.saveStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("新建报销单") { createDraft() }
                    Button("AI 设置") { controls.showingAISettings = true }
                    Button("打开 / 管理报销单") { openDraftPicker() }
                        .disabled(controls.exportingInvoices)
                }
                .padding(.horizontal)

                Divider()

                HStack(spacing: 12) {
                    Picker("区域", selection: $controls.showingInvoices) {
                        Text("订单截图").tag(false)
                        Text("项目发票夹").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    if controls.showingInvoices {
                        Button("导入发票") { chooseInvoices() }
                        Button("从发票箱选择") { openInbox(target: controls.draft) }
                        Spacer()
                        Button(controls.exportingInvoices ? "正在导出…" : "导出发票文件夹") { exportInvoices() }
                            .disabled(invoices.invoices.isEmpty || controls.exportingInvoices || invoices.confirmationCount > 0)
                    } else {
                        Button("导入截图") { chooseImages() }
                        Spacer()
                        Button("导出 Excel") { saveWorkbook() }
                            .disabled(store.expenses.isEmpty)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal)

                if !controls.showingInvoices {
                HStack(spacing: 12) {
                    TextField("搜索已填写金额，例如 39", text: $controls.amountQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .accessibilityLabel("搜索已填写金额")
                    if !controls.amountQuery.isEmpty {
                        Button("清空搜索") { controls.amountQuery = "" }
                    }
                    Toggle("只看待处理", isOn: $controls.onlyNeedsReview)
                        .toggleStyle(.checkbox)
                    Text("显示 \(visibleExpenses.count) / \(store.expenses.count) 笔")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("全部标记已人工核对") { store.confirmAll() }
                        .disabled(store.expenses.isEmpty || !store.pendingIDs.isEmpty || !store.aiPendingIDs.isEmpty)
                    Button {
                        controls.showingOrderPreview.toggle()
                    } label: {
                        Label("截图预览", systemImage: "sidebar.right")
                    }
                    .help(controls.showingOrderPreview ? "收起右侧截图预览" : "显示右侧截图预览")
                }
                .padding(.horizontal)
                HSplitView {
                VStack(spacing: 8) {
                HStack(spacing: 0) {
                    header("序号", width: 64)
                    header("日期", width: 128)
                    header("名称", width: nil)
                    header("图片", width: 160)
                    header("金额", width: 160)
                }
                .padding(.horizontal)

                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if visibleExpenses.isEmpty && !store.expenses.isEmpty {
                            Text(controls.onlyNeedsReview && store.reviewCount == 0
                                 ? "待处理问题已全部处理完毕"
                                 : "没有符合条件的订单，请调整搜索或筛选条件。")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(visibleExpenses) { $expense in
                            ExpenseRow(expense: $expense, store: store,
                                showPreview: { controls.previewURL = expense.sourceURL },
                                delete: {
                                    if selection.selectedID == expense.id { selection.selectedID = nil }
                                    store.delete(expense.id)
                                })
                                .id(expense.id)
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
                .onChange(of: controls.scrollTargetID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                    controls.scrollTargetID = nil
                }
                }
                .frame(minWidth: 780)
                }
                if controls.showingOrderPreview {
                    OrderPreviewPanel(
                        expense: store.expenses.first {
                            $0.id == selection.selectedID && store.matchesFilters($0,
                                amountQuery: controls.amountQuery, onlyNeedsReview: controls.onlyNeedsReview)
                        },
                        enlarge: { controls.previewURL = $0 },
                        close: { controls.showingOrderPreview = false }
                    )
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 500)
                }
                }
                } else {
                    if !controls.exportStatus.isEmpty {
                        Text(controls.exportStatus).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    InvoiceSummaryView(orderTotal: store.amountTotal, invoiceTotal: invoices.total,
                                       confirmationCount: invoices.confirmationCount,
                                       hasUnresolvedAmounts: store.hasUnresolvedAmounts)
                        .padding(.horizontal)
                    invoiceList
                }

                HStack {
                    if controls.showingInvoices {
                        Text("已导入发票 \(invoices.invoices.count) 张 · 原格式独立导出")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("已导入 \(store.expenses.count) 张 · 有效 \(store.exportExpenses.count) 笔 · 待处理 \(store.reviewCount) 笔 · 已填订单总额 ¥\(currency(store.total))")
                    }
                    Spacer()
                    if !controls.showingInvoices {
                        Button(store.undoActionName.map { "撤销\($0)" } ?? "撤销") {
                            store.undoLastAction()
                        }
                        .disabled(store.undoActionName == nil)
                    }
                    if !controls.showingInvoices, blocker != nil, !store.expenses.isEmpty {
                        Button("查看待处理问题") {
                            if let first = store.exportIssues.first { locateExpense(first.id) }
                            else { controls.showingExportIssues = true }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            if let previewURL = controls.previewURL {
                ImagePreview(url: previewURL) { controls.previewURL = nil }
            }
        }
        .frame(minWidth: controls.showingOrderPreview && !controls.showingInvoices ? 1120 : 1020, minHeight: 620)
        .background {
            Button("撤销") {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
                    editor.undoManager?.undo()
                } else if !controls.showingInvoices {
                    store.undoLastAction()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .hidden().accessibilityHidden(true)
        }
        .overlay {
            if controls.isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.blue, lineWidth: 3)
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $controls.isDropTarget, perform: importDroppedImages)
        .onChange(of: visibleExpenses.map { $0.wrappedValue.id }) { previous, current in
            guard controls.onlyNeedsReview, let selectedID = selection.selectedID,
                  let expense = store.expenses.first(where: { $0.id == selectedID }),
                  !store.needsReview(expense), !current.contains(selectedID),
                  let previousIndex = previous.firstIndex(of: selectedID) else { return }
            let next = previous.dropFirst(previousIndex + 1).first(where: current.contains)
                ?? previous.prefix(previousIndex).reversed().first(where: current.contains)
                ?? current.first
            selection.selectedID = next
            if let next {
                controls.showingOrderPreview = true
                controls.scrollTargetID = next
            }
        }
        .onChange(of: controls.title) { _, _ in scheduleSave() }
        .sheet(isPresented: $controls.showingExportIssues) {
            VStack(alignment: .leading, spacing: 12) {
                Text("导出前需要处理的问题").font(.title2)
                Text("点击订单可返回并定位；导出始终包含完整报销单。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("请填写报销单标题", text: $controls.title).textFieldStyle(.roundedBorder)
                if store.exportIssues.isEmpty, let blocker { Text(blocker).foregroundStyle(.orange) }
                List(store.exportIssues) { issue in
                    Button {
                        locateExpense(issue.id)
                    } label: {
                        HStack {
                            Text("第 \(issue.number) 笔").bold().frame(width: 70, alignment: .leading)
                            Text(issue.reasons.joined(separator: "；"))
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Button("返回修改") { controls.showingExportIssues = false }
                    Spacer()
                    if blocker == nil {
                        Button("问题已处理，返回导出") { controls.showingExportIssues = false }
                    }
                }
            }
            .padding()
            .frame(width: 620, height: 380)
        }
        .sheet(isPresented: $controls.showingAISettings) {
            AISettingsView(close: { controls.showingAISettings = false }, saved: {
                store.invalidateAIRequests()
                store.automaticallyAssistUnresolvedExpenses()
            })
        }
        .sheet(isPresented: $controls.showingDrafts) {
            VStack(alignment: .leading, spacing: 12) {
                Text("管理报销单").font(.title2)
                List(controls.availableDrafts) { item in
                    HStack(spacing: 12) {
                    Button {
                        openDraft(item)
                        controls.showingDrafts = false
                    } label: {
                        HStack {
                            Text(item.title)
                            if controls.draft?.id == item.id { Text("当前").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(item.updatedAt, style: .date).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Button("重命名") { renameDraft(item) }
                    Button("移入废纸篓", role: .destructive) { trashDraft(item) }
                    }
                }
                Button("取消") { controls.showingDrafts = false }
            }
            .padding()
            .frame(width: 680, height: 360)
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
            controls.previewURL = nil
            selection.selectedID = nil
            store.reset()
            invoices.configure(directory: created.url)
            controls.title = created.title
            controls.saveStatus = "已保存"
            controls.showingInvoices = false
            controls.showingInbox = false
            controls.inboxTarget = nil
            controls.amountQuery = ""
            controls.onlyNeedsReview = false
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
            controls.previewURL = nil
            selection.selectedID = nil
            controls.draft = opened
            invoices.configure(directory: opened.url)
            controls.title = opened.title
            controls.saveStatus = "已保存"
            controls.showingInvoices = false
            controls.showingInbox = false
            controls.inboxTarget = nil
            controls.amountQuery = ""
            controls.onlyNeedsReview = false
        } catch { controls.errorMessage = "打开草稿失败：\(error.localizedDescription)" }
    }

    private func renameDraft(_ selected: DraftSummary) {
        let alert = NSAlert()
        alert.messageText = "重命名报销单"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: selected.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let renamed = try DraftStorage.rename(selected, to: field.stringValue)
            if controls.draft?.id == selected.id {
                controls.draft = renamed
                controls.title = renamed.title
            }
            controls.availableDrafts = try DraftStorage.list()
        } catch {
            controls.showingDrafts = false
            controls.errorMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    private func trashDraft(_ selected: DraftSummary) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将“\(selected.title)”移入废纸篓？"
        alert.informativeText = "该报销单及其保存的订单截图和发票将一起移入废纸篓，原始导入文件不受影响。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移入废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        controls.saveTask?.cancel()
        saveCurrent()
        guard controls.saveStatus != "保存失败" else { return }
        do {
            try DraftStorage.moveToTrash(selected)
            if controls.draft?.id == selected.id {
                controls.draft = nil
                controls.previewURL = nil
                selection.selectedID = nil
                store.reset()
                let remaining = try DraftStorage.list()
                if let next = remaining.first { openDraft(next) }
                else { createDraft() }
            }
            controls.availableDrafts = try DraftStorage.list()
        } catch {
            controls.showingDrafts = false
            controls.errorMessage = "操作已停止：\(error.localizedDescription)"
        }
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
                let folder = try await invoices.exportFolder(to: parent)
                controls.exportStatus = "已导出发票文件夹"
                NSWorkspace.shared.open(folder)
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

    private func locateExpense(_ id: UUID) {
        controls.amountQuery = ""
        controls.onlyNeedsReview = false
        controls.showingInvoices = false
        controls.showingOrderPreview = true
        selection.selectedID = id
        controls.showingExportIssues = false
        controls.scrollTargetID = id
    }

    private func saveWorkbook() {
        guard blocker == nil else {
            controls.showingExportIssues = true
            return
        }
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
            else if store.needsConfirmation(invoice) { Text("待确认金额").font(.caption).foregroundStyle(.orange) }
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
    @Published var showingInbox = false
    @Published var inboxTarget: DraftSummary?
    @Published var showingMailboxSettings = false
    @Published var title = "报销单"
    @Published var previewURL: URL?
    @Published var errorMessage: String?
    @Published var isDropTarget = false
    @Published var draft: DraftSummary?
    @Published var availableDrafts: [DraftSummary] = []
    @Published var showingDrafts = false
    @Published var showingAISettings = false
    @Published var showingExportIssues = false
    @Published var scrollTargetID: UUID?
    @Published var showingInvoices = false
    @Published var showingOrderPreview = true
    @Published var amountQuery = ""
    @Published var onlyNeedsReview = false
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
            VStack(alignment: .leading, spacing: 5) {
            LiveDateField(text: Binding(
                get: { expense.date },
                set: { value in
                    store.markEdited(expense.id, field: .date)
                    expense.date = value
                }
            ))
                if let dates = store.dateCandidates[expense.id], !dates.isEmpty {
                    Text("选择支付日期").font(.caption).foregroundStyle(.secondary)
                    ForEach(dates, id: \.self) { date in
                        Button(date) { store.selectDateCandidate(date, for: expense.id) }
                            .controlSize(.small).disabled(expense.isDuplicate)
                    }
                }
            }
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
                    Text(store.status(for: expense).title)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(statusColor)
                        .background(statusColor.opacity(0.12), in: Capsule())
                    if store.confirmedWarnings.contains(expense.id) {
                        Text("已人工核对").font(.caption).foregroundStyle(.secondary)
                    } else if expense.aiRecognized == true {
                        Text("AI 已识别").font(.caption).foregroundStyle(.secondary)
                    }
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
                if store.pendingIDs.contains(expense.id) || store.aiPendingIDs.contains(expense.id) {
                    ProgressView().controlSize(.small)
                }
                if let note = store.aiNotes[expense.id] {
                    Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !store.pendingIDs.contains(expense.id), !expense.isDuplicate {
                    let reasons = store.issues(for: expense)
                    if !reasons.isEmpty {
                        Text(reasons.joined(separator: "；")).font(.caption).foregroundStyle(.orange)
                    }
                }
                if !expense.isDuplicate && !store.pendingIDs.contains(expense.id) {
                    Button(store.aiPendingIDs.contains(expense.id) ? "AI 判断中…" : "AI 辅助识别") {
                        store.classifyWithAI(expense.id)
                    }
                    .font(.caption)
                    .disabled(store.aiPendingIDs.contains(expense.id) || store.recognizedTexts[expense.id]?.isEmpty != false)
                    Toggle("已人工核对", isOn: Binding(
                        get: { store.confirmedWarnings.contains(expense.id) },
                        set: { checked in
                            if checked { store.confirmedWarnings.insert(expense.id) }
                            else { store.confirmedWarnings.remove(expense.id) }
                        }
                    ))
                    .font(.caption)
                    .disabled(store.aiPendingIDs.contains(expense.id))
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
                    .onChange(of: store.aiAmountUpdates[expense.id]) { _, update in
                        guard update != nil, store.aiAmountUpdates[expense.id] != nil else { return }
                        amountDraft.edited = false
                        amountDraft.text = expense.amount.map { "\($0)" } ?? ""
                    }
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

    private var statusColor: Color {
        switch store.status(for: expense) {
        case .processing: .blue
        case .incomplete, .needsReview: .orange
        case .reviewed, .aiRecognized, .ready: .green
        case .duplicate: .secondary
        }
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
