import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor private final class InvoiceInboxControls: ObservableObject {
    @Published var selected: Set<UUID> = []
    @Published var buyer = "全部抬头"
    @Published var assignment = "全部状态"
    @Published var dateFilter = false
    @Published var start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var end = Date()
    @Published var choosingProject = false
    @Published var edit: InboxInvoice?
    @Published var amount = ""
    @Published var title = ""
    @Published var preview: URL?
    @Published var error: String?
    @Published var busy = false
    @Published var dropTarget = false
    @Published var documentFilter = "发票与待确认"
    @Published var deleteIDs: Set<UUID> = []
    @Published var confirmingDelete = false
    @Published var confirmInvoiceID: UUID?
    @Published var confirmingDocument = false
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

    private var filtered: [InboxInvoice] {
        inbox.items.filter { item in
            (controls.documentFilter == "全部附件" || (controls.documentFilter == "已排除附件" ? item.documentKind == .nonInvoice : item.documentKind != .nonInvoice)) &&
            (controls.buyer == "全部抬头" || (controls.buyer == "抬头未知" ? item.buyerTitle.isEmpty : item.buyerTitle == controls.buyer)) &&
            (controls.assignment == "全部状态" || (controls.assignment == "未分配" ? item.projectID == nil : item.projectID != nil)) &&
            (!controls.dateFilter || InvoiceInboxDates.contains(item.receivedAt, from: controls.start, through: controls.end))
        }.sorted { $0.receivedAt > $1.receivedAt }
    }
    private var selectable: Set<UUID> { Set(filtered.filter { !inbox.pendingIDs.contains($0.id) }.map(\.id)) }
    private var chosen: Set<UUID> { controls.selected.intersection(selectable).intersection(Set(inbox.items.filter { $0.projectID == nil && $0.documentKind != .nonInvoice }.map(\.id))) }
    private var monthGroups: [Date] { InvoiceInboxDates.months(filtered.map(\.receivedAt)) }
    private var joiningTitle: String {
        let downloads = inbox.items.contains { chosen.contains($0.id) && !inbox.isDownloaded($0) }
        let action = downloads ? "下载并加入" : "加入"
        return targetProject.map { action + "“" + $0.title + "”" } ?? action + "项目"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("发票箱").font(.title2.bold())
                Spacer()
                Button(syncing ? "同步中…" : "同步邮箱", action: sync).disabled(syncing)
                Button("导入发票", action: importFiles)
            }
            if !syncStatus.isEmpty { Text(syncStatus).font(.caption).foregroundStyle(.secondary) }
            filters
            HStack {
                Toggle("全选当前结果", isOn: Binding(get: { !selectable.isEmpty && selectable.isSubset(of: controls.selected) }, set: {
                    if $0 { controls.selected.formUnion(selectable) } else { controls.selected.subtract(selectable) }
                })).toggleStyle(.checkbox)
                Text("已选 \(controls.selected.intersection(Set(filtered.map(\.id))).count) 张").foregroundStyle(.secondary)
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
                        Text(groupTitle(group)).font(.headline).padding(.top, 8)
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
        .sheet(isPresented: Binding(get: { controls.preview != nil }, set: { if !$0 { controls.preview = nil } })) {
            if let url = controls.preview { ImagePreview(url: url) { controls.preview = nil }.frame(minWidth: 700, minHeight: 600) }
        }
        .confirmationDialog("删除所选发票箱记录？", isPresented: $controls.confirmingDelete, titleVisibility: .visible) {
            Button("删除记录并将缓存移入废纸篓", role: .destructive) {
                do {
                    try inbox.delete(ids: controls.deleteIDs)
                    controls.selected.subtract(controls.deleteIDs)
                } catch { controls.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("仅删除发票箱记录和本地缓存，不影响项目副本、已导出文件或邮箱原件。") }
        .confirmationDialog("确认此附件是发票？", isPresented: $controls.confirmingDocument, titleVisibility: .visible) {
            Button("确认为发票") {
                if let id = controls.confirmInvoiceID {
                    do { try inbox.confirmInvoice(id) } catch { controls.error = error.localizedDescription }
                }
                controls.confirmInvoiceID = nil
            }
            Button("取消", role: .cancel) { controls.confirmInvoiceID = nil }
        } message: { Text("请先预览并核对附件内容；文件类型确认不代表税务验真。") }
        .alert("操作失败", isPresented: Binding(get: { controls.error != nil }, set: { if !$0 { controls.error = nil } })) {
            Button("确定") { controls.error = nil }
        } message: { Text(controls.error ?? "") }
    }

    private var filters: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("附件类型", selection: $controls.documentFilter) {
                    ForEach(["发票与待确认", "已排除附件", "全部附件"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 220)
                Picker("购买方抬头", selection: $controls.buyer) {
                    Text("全部抬头").tag("全部抬头")
                    Text("抬头未知").tag("抬头未知")
                    ForEach(Array(Set(inbox.items.map(\.buyerTitle).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 380)
                Picker("分配状态", selection: $controls.assignment) {
                    ForEach(["全部状态", "未分配", "已分配"], id: \.self) { Text($0).tag($0) }
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

    private func card(_ item: InboxInvoice) -> some View {
        let downloaded = inbox.isDownloaded(item)
        let pending = inbox.pendingIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Toggle("选择发票", isOn: Binding(get: { controls.selected.contains(item.id) }, set: {
                    if $0 { controls.selected.insert(item.id) } else { controls.selected.remove(item.id) }
                })).labelsHidden().toggleStyle(.checkbox).disabled(pending || controls.busy)
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
            Text(item.documentKind == .invoice ? "发票" : item.documentKind == .nonInvoice ? "已排除：非发票附件" : "待确认附件类型")
                .font(.caption).foregroundStyle(item.documentKind == .invoice ? Color.secondary : Color.orange)
            if let reason = item.documentReason, item.documentKind != .invoice { Text(reason).font(.caption).foregroundStyle(.secondary) }
            Text("购买方：" + (item.buyerTitle.isEmpty ? (downloaded ? "抬头未知" : "下载后识别抬头") : item.buyerTitle))
            if !item.itemDescription.isEmpty { Text("内容：" + item.itemDescription).lineLimit(2) }
            HStack {
                Text("归属项目：" + (item.projectID.map { id in projects.first(where: { $0.id == id })?.title ?? "已分配项目" } ?? "未分配"))
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
                if downloaded && item.documentKind != .invoice {
                    Button("确认为发票") { controls.confirmInvoiceID = item.id; controls.confirmingDocument = true }.disabled(pending || controls.busy)
                }
                Button("删除", role: .destructive) { controls.deleteIDs = [item.id]; controls.confirmingDelete = true }
                    .disabled(pending || controls.busy)
                Button("修改金额与抬头") {
                    controls.amount = item.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
                    controls.title = item.buyerTitle
                    controls.edit = item
                }.disabled(item.projectID != nil || pending || controls.busy)
            }
        }
        .font(.callout).padding(16)
        .background(controls.selected.contains(item.id) ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
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
    private func preview(_ item: InboxInvoice) {
        Task {
            do {
                let downloadedIDs = try await inbox.download(item.id)
                guard downloadedIDs.contains(item.id) else {
                    controls.selected.remove(item.id)
                    return
                }
                let url = inbox.sourceURL(for: item)
                if ["pdf", "zip"].contains(url.pathExtension.lowercased()) { NSWorkspace.shared.open(url) }
                else { controls.preview = url }
            } catch { controls.error = error.localizedDescription }
        }
    }
    private func assign(to project: DraftSummary) {
        let ids = chosen
        controls.busy = true
        inbox.activeCacheIDs.formUnion(ids)
        Task {
            defer { controls.busy = false; inbox.activeCacheIDs.subtract(ids) }
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
