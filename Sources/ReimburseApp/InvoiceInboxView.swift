import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor private final class InvoiceInboxControls: ObservableObject {
    @Published var selected: Set<UUID> = []
    var previewRequest: UUID?
    var assigningIDs: Set<UUID> = []
    @Published var previewID: UUID?
    @Published var previewURL: URL?
    @Published var previewTitle = ""
    @Published var buyer = "全部抬头"
    @Published var assignment = "全部状态"
    @Published var dateFilter = false
    @Published var start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var end = Date()
    @Published var choosingProject = false
    @Published var edit: InboxInvoice?
    @Published var amount = ""
    @Published var title = ""
    @Published var error: String?
    @Published var busy = false
    @Published var dropTarget = false
    @Published var documentFilter = "发票"
    @Published var deleteIDs: Set<UUID> = []
    @Published var confirmingDelete = false
}

struct InvoiceInboxView: View {
    @ObservedObject var inbox: InvoiceInboxStore
    let projects: [DraftSummary]
    let targetProject: DraftSummary?
    let sync: () -> Void
    let syncing: Bool
    let syncStatus: String
    let assigned: () -> Void
    @StateObject private var controls = InvoiceInboxControls()
    @Environment(\.mailDetailIsOpen) private var mailDetailIsOpen
    @Environment(\.closeMailDetail) private var closeMailDetail

    private var filtered: [InboxInvoice] {
        inbox.items.filter { item in
            (controls.documentFilter == "发票" ? item.isAcceptedInvoice : controls.documentFilter == "待下载附件" ? !inbox.isDownloaded(item) && !item.isAcceptedInvoice && item.documentKind != .nonInvoice : inbox.isDownloaded(item) && !item.isAcceptedInvoice || item.documentKind == .nonInvoice) &&
            (controls.buyer == "全部抬头" || (controls.buyer == "抬头未知" ? item.buyerTitle.isEmpty : item.buyerTitle == controls.buyer)) &&
            (controls.assignment == "全部状态" || (controls.assignment == "未加入" ? item.projectID == nil : item.projectID != nil)) &&
            (!controls.dateFilter || InvoiceInboxDates.contains(item.receivedAt, from: controls.start, through: controls.end))
        }.sorted { $0.receivedAt > $1.receivedAt }
    }
    private var selectable: Set<UUID> { Set(filtered.filter { !inbox.pendingIDs.contains($0.id) }.map(\.id)) }
    private var chosen: Set<UUID> { controls.selected.intersection(selectable).intersection(Set(inbox.items.filter { $0.projectID == nil && $0.isAcceptedInvoice }.map(\.id))) }
    private var selectedItems: [InboxInvoice] { filtered.filter { controls.selected.contains($0.id) } }
    private var selectedTotal: Decimal { selectedItems.filter { ($0.amount ?? .zero) > 0 }.reduce(.zero) { $0 + ($1.amount ?? .zero) } }
    private var monthGroups: [Date] { InvoiceInboxDates.months(filtered.map(\.receivedAt)) }
    private var joiningTitle: String {
        let downloads = inbox.items.contains { chosen.contains($0.id) && !inbox.isDownloaded($0) }
        let action = downloads ? "下载并加入" : "加入"
        return targetProject.map { action + "“" + $0.title + "”" } ?? action + "项目"
    }

    var body: some View {
        HSplitView {
            inboxContent.frame(minWidth: 650)
            if controls.previewID != nil {
                AttachmentSidePreview(url: controls.previewURL, title: controls.previewTitle, close: closePreview)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 500)
            }
        }
        .onChange(of: mailDetailIsOpen) { _, open in if open { closePreview() } }
        .onDisappear { closePreview() }
        .onChange(of: inbox.items.map(\.id)) { _, ids in
            if let id = controls.previewID, !ids.contains(id) { closePreview() }
        }
    }

    private var inboxContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("发票箱").font(.title2.bold())
                Spacer()
                Button(syncing ? "同步中…" : "同步邮箱", action: sync).disabled(syncing)
                Button("导入发票", action: importFiles)
            }
            if !syncStatus.isEmpty { Text(syncStatus).font(.caption).foregroundStyle(.secondary) }
            filters
            Text("只收录通过自动检查的电子普通发票；新收附件自动下载识别；历史或下载失败的附件可在“待下载附件”中手动下载。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("全选当前结果", isOn: Binding(get: { !selectable.isEmpty && selectable.isSubset(of: controls.selected) }, set: {
                    if $0 { controls.selected.formUnion(selectable) } else { controls.selected.subtract(selectable) }
                })).toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已选 \(selectedItems.count) 张，合计 ¥\(selectedTotal.formatted(.number.precision(.fractionLength(2))))")
                    if selectedItems.contains(where: { ($0.amount ?? .zero) <= 0 }) {
                        Text("未填写有效金额的附件暂不计入合计").font(.caption)
                    }
                }.foregroundStyle(.secondary)
                Spacer()
                Button("删除所选", role: .destructive) {
                    controls.deleteIDs = controls.selected.intersection(Set(filtered.map(\.id)))
                    controls.confirmingDelete = true
                }.disabled(controls.selected.intersection(Set(filtered.map(\.id))).isEmpty || controls.busy)
                Button(joiningTitle) {
                    if let project = targetProject { assign(to: project) } else { controls.choosingProject = true }
                }.disabled(chosen.isEmpty || controls.busy)
            }
            if let error = inbox.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if filtered.isEmpty {
                        Text("暂无符合条件的发票。可同步邮箱，或拖入图片、PDF、ZIP 文件。")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                    ForEach(monthGroups, id: \.self) { group in
                        monthHeader(group)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(filtered.filter { month($0.receivedAt) == group }) { item in card(item) }
                        }
                    }
                }.padding(2)
            }
        }
        .padding(20)
        .overlay { if controls.dropTarget { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $controls.dropTarget, perform: dropped)
        .sheet(isPresented: $controls.choosingProject) { projectSheet }
        .sheet(item: $controls.edit) { _ in editSheet }
        .confirmationDialog("删除所选发票箱记录？", isPresented: $controls.confirmingDelete, titleVisibility: .visible) {
            Button("删除记录并将缓存移入废纸篓", role: .destructive) {
                do {
                    if let id = controls.previewID, controls.deleteIDs.contains(id) { closePreview() }
                    try inbox.delete(ids: controls.deleteIDs)
                    controls.selected.subtract(controls.deleteIDs)
                } catch { controls.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("仅删除发票箱记录和本地缓存，不影响项目副本、已导出文件或邮箱原件。") }
        .alert("操作失败", isPresented: Binding(get: { controls.error != nil }, set: { if !$0 { controls.error = nil } })) {
            Button("确定") { controls.error = nil }
        } message: { Text(controls.error ?? "") }
    }

    private var filters: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("附件类型", selection: $controls.documentFilter) {
                    ForEach(["发票", "待下载附件", "已排除附件"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 220)
                Picker("购买方抬头", selection: $controls.buyer) {
                    Text("全部抬头").tag("全部抬头")
                    Text("抬头未知").tag("抬头未知")
                    ForEach(Array(Set(inbox.items.map(\.buyerTitle).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 380)
                Picker("分配状态", selection: $controls.assignment) {
                    ForEach(["全部状态", "未加入", "已加入"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 210)
                Spacer()
            }
            HStack {
                Toggle("收件日期", isOn: $controls.dateFilter).toggleStyle(.checkbox)
                DatePicker("从", selection: $controls.start, displayedComponents: .date).labelsHidden()
                Text("至")
                DatePicker("至", selection: $controls.end, displayedComponents: .date).labelsHidden()
                Spacer()
            }
        }
    }

    private func monthHeader(_ group: Date) -> some View {
        let items = filtered.filter { month($0.receivedAt) == group }
        let unassigned = items.filter { $0.projectID == nil && $0.isAcceptedInvoice }
        let eligible = Set(unassigned.filter { !inbox.pendingIDs.contains($0.id) }.map(\.id))
        let selected = controls.selected.intersection(eligible)
        let all = !eligible.isEmpty && selected == eligible
        return Button {
            if all { controls.selected.subtract(eligible) }
            else { controls.selected.formUnion(eligible) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: all ? "checkmark.square.fill" : selected.isEmpty ? "square" : "minus.square.fill")
                    .foregroundStyle(eligible.isEmpty ? Color.secondary : Color.accentColor)
                Text(groupTitle(group)).font(.headline)
                Text("· \(items.count) 张 · \(unassigned.count) 张未加入").foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.top, 8)
        .disabled(eligible.isEmpty || controls.busy)
        .accessibilityLabel("\(groupTitle(group))，选择该月未加入项目的发票")
        .accessibilityValue(all ? "全部选中" : selected.isEmpty ? "未选中" : "部分选中")
        .help("点击选择该月当前筛选下未加入项目的合格发票，再次点击取消")
    }

    private func card(_ item: InboxInvoice) -> some View {
        let downloaded = inbox.isDownloaded(item)
        let pending = inbox.pendingIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Toggle("选择发票", isOn: Binding(get: { controls.selected.contains(item.id) }, set: {
                    if $0 { controls.selected.insert(item.id) } else { controls.selected.remove(item.id) }
                })).labelsHidden().toggleStyle(.checkbox).disabled(pending || controls.busy)
                Button { preview(item) } label: {
                    AttachmentThumbnail(url: inbox.sourceURL(for: item), downloaded: downloaded)
                }.buttonStyle(.plain).disabled(pending || controls.busy)
                    .accessibilityLabel("预览发票附件")
                VStack(alignment: .leading, spacing: 5) {
                    Button { preview(item) } label: {
                        Text(item.sellerTitle.isEmpty ? item.originalFilename : item.sellerTitle).font(.headline).lineLimit(2)
                    }.buttonStyle(.plain).help("点击预览发票")
                    Text("收件日期：\(item.receivedAt.formatted(date: .numeric, time: .omitted))").foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.amount.map { "¥" + $0.formatted(.number.precision(.fractionLength(2))) } ?? (downloaded ? "金额待填写" : "下载后识别金额"))
                    .font(.title3.weight(.semibold)).monospacedDigit()
            }
            Text(item.isAcceptedInvoice ? "电子普通发票" : !downloaded && item.documentKind != .nonInvoice ? "待下载自动识别" : "已排除：未通过发票检查")
                .font(.caption).foregroundStyle(item.isAcceptedInvoice ? Color.secondary : Color.orange)
            if let reason = item.documentReason, !item.isAcceptedInvoice { Text(reason).font(.caption).foregroundStyle(.secondary) }
            Text("购买方：" + (item.buyerTitle.isEmpty ? (downloaded ? "抬头未知" : "下载后识别抬头") : item.buyerTitle))
            if !item.itemDescription.isEmpty { Text("内容：" + item.itemDescription).lineLimit(2) }
            HStack {
                Text(item.projectID.map { id in "已加入 · " + (projects.first(where: { $0.id == id })?.title ?? "项目") } ?? "未加入项目")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(item.projectID == nil ? Color.secondary : Color.green)
                    .background(item.projectID == nil ? Color.primary.opacity(0.05) : Color.green.opacity(0.1), in: Capsule())
                Spacer()
                Text("来源：" + item.source).foregroundStyle(.secondary)
            }
            HStack {
                if pending { ProgressView().controlSize(.small); Text("处理中…").foregroundStyle(.secondary) }
                else if !downloaded { Text("未下载").foregroundStyle(.secondary) }
                if let warning = item.warning { Text(warning).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                if !downloaded { Button("下载") { download(item) }.disabled(pending || controls.busy) }
                Button(downloaded ? "预览" : "下载并预览") { preview(item) }.disabled(pending || controls.busy)
                Button("删除", role: .destructive) { controls.deleteIDs = [item.id]; controls.confirmingDelete = true }
                    .disabled(pending || controls.busy)
                Button("修改金额与抬头") {
                    controls.amount = item.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
                    controls.title = item.buyerTitle
                    controls.edit = item
                }.disabled(!item.isAcceptedInvoice || item.projectID != nil || pending || controls.busy)
            }
        }
        .font(.callout).padding(16)
        .background(controls.selected.contains(item.id) ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if controls.previewID == item.id {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
            }
        }
    }

    private var projectSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("将 \(chosen.count) 张发票加入项目").font(.headline)
            Text("未下载的附件将在加入时下载并识别。已分配的发票不会重复加入。").foregroundStyle(.secondary)
            if projects.isEmpty { Text("请先创建并保存一个报销项目。") }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(projects) { project in Button(project.title) { controls.choosingProject = false; assign(to: project) } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("取消") { controls.choosingProject = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 460, height: 320)
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改发票").font(.headline)
            TextField("金额", text: $controls.amount)
            TextField("购买方公司抬头", text: $controls.title)
            HStack {
                Spacer()
                Button("取消") { controls.edit = nil }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let item = controls.edit else { return }
                    do { try inbox.update(item.id, amount: controls.amount, buyerTitle: controls.title); controls.edit = nil }
                    catch { controls.edit = nil; controls.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
    }

    private func month(_ date: Date) -> Date {
        InvoiceInboxDates.month(date)
    }
    private func groupTitle(_ date: Date) -> String {
        if date == month(Date()) { return "本月" }
        if date == month(Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()) { return "上月" }
        return date.formatted(.dateTime.year().month(.twoDigits).locale(Locale(identifier: "zh_CN")))
    }
    private func download(_ item: InboxInvoice) {
        Task { do { try await inbox.download(item.id) } catch { controls.error = error.localizedDescription } }
    }
    private func closePreview() {
        controls.previewRequest = nil
        if let id = controls.previewID, !controls.assigningIDs.contains(id) { inbox.activeCacheIDs.remove(id) }
        controls.previewID = nil
        controls.previewURL = nil
        controls.previewTitle = ""
        inbox.onCacheChanged?([])
    }
    private func preview(_ item: InboxInvoice) {
        closeMailDetail()
        guard !controls.busy else { return }
        if controls.previewID == item.id, controls.previewURL != nil || controls.previewRequest != nil { return }
        closePreview()
        let request = UUID()
        controls.previewRequest = request
        controls.previewID = item.id
        controls.previewTitle = "正在载入 · " + item.originalFilename
        inbox.activeCacheIDs.insert(item.id)
        Task {
            do {
                let downloadedIDs = try await inbox.download(item.id)
                guard controls.previewRequest == request else { return }
                controls.previewRequest = nil
                controls.previewTitle = item.originalFilename
                guard downloadedIDs.contains(item.id) else {
                    controls.error = "附件已展开，请选择其中的发票查看。"
                    closePreview()
                    return
                }
                controls.previewURL = inbox.sourceURL(for: item)
            } catch {
                guard controls.previewRequest == request else { return }
                controls.previewRequest = nil
                controls.previewTitle = item.originalFilename
                controls.error = error.localizedDescription
            }
        }
    }
    private func assign(to project: DraftSummary) {
        let ids = chosen
        controls.busy = true
        controls.assigningIDs = ids
        inbox.activeCacheIDs.formUnion(ids)
        Task {
            defer {
                controls.busy = false
                controls.assigningIDs = []
                inbox.activeCacheIDs.subtract(ids)
                if let id = controls.previewID { inbox.activeCacheIDs.insert(id) }
            }
            do {
                var downloadedIDs: Set<UUID> = []
                for id in ids { downloadedIDs.formUnion(try await inbox.download(id)) }
                try inbox.assign(ids: downloadedIDs, to: project)
                controls.selected.subtract(ids)
                assigned()
            } catch { controls.error = error.localizedDescription }
        }
    }
    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .zip]
        if panel.runModal() == .OK { let urls = panel.urls; Task { await inbox.importFiles(urls) } }
    }
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        let matches = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in matches {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in await inbox.importFiles([url]) }
            }
        }
        return !matches.isEmpty
    }
}


// Kept pure so month boundaries and inclusive date filters can be checked offline.
enum InvoiceInboxDates {
    static func month(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
    static func months(_ dates: [Date], calendar: Calendar = .current) -> [Date] {
        Array(Set(dates.map { month($0, calendar: calendar) })).sorted(by: >)
    }
    static func contains(_ date: Date, from start: Date, through end: Date, calendar: Calendar = .current) -> Bool {
        let afterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        return date >= calendar.startOfDay(for: start) && date < afterEnd
    }
}

#if DIRECT_TEST_RUNNER
func checkInvoiceInboxDates() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    let input = [date(2025, 12, 31), date(2026, 1, 1), date(2024, 6, 1), date(2026, 1, 20)]
    assert(InvoiceInboxDates.months(input, calendar: calendar) == [date(2026, 1, 1), date(2025, 12, 1), date(2024, 6, 1)])
    assert(InvoiceInboxDates.months([], calendar: calendar).isEmpty)
    assert(InvoiceInboxDates.contains(date(2025, 12, 31, 23), from: date(2025, 12, 31, 12), through: date(2026, 1, 1), calendar: calendar))
    assert(InvoiceInboxDates.contains(date(2026, 1, 1, 23), from: date(2025, 12, 31), through: date(2026, 1, 1), calendar: calendar))
    assert(!InvoiceInboxDates.contains(date(2026, 1, 2), from: date(2025, 12, 31), through: date(2026, 1, 1), calendar: calendar))
}
#endif
