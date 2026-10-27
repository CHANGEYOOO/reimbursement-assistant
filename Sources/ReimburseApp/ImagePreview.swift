import AppKit
import Combine
import PDFKit
import SwiftUI

private struct PreviewFrames: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
private struct PreviewAction: EnvironmentKey { static let defaultValue: @MainActor @Sendable (URL) -> Void = { _ in } }
extension EnvironmentValues {
    var attachmentPreview: @MainActor @Sendable (URL) -> Void {
        get { self[PreviewAction.self] }
        set { self[PreviewAction.self] = newValue }
    }
}
extension View {
    func attachmentPreviewHost(url: Binding<URL?>) -> some View { modifier(PreviewHost(url: url)) }
    func attachmentPreviewSource(url: URL) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: PreviewFrames.self, value: [url: proxy.frame(in: .named("attachmentPreviewWindow"))]) })
    }
}
@MainActor private final class HostState: ObservableObject { @Published var frames: [URL: CGRect] = [:] }
private struct PreviewHost: ViewModifier {
    @Binding var url: URL?
    @StateObject private var state = HostState()
    func body(content: Content) -> some View {
        content.environment(\.attachmentPreview, { url = $0 })
            .onPreferenceChange(PreviewFrames.self) { state.frames = $0 }
            .overlay { if let url { PreviewOverlay(url: url, source: state.frames[url]) { self.url = nil }.id(url) } }
            .coordinateSpace(name: "attachmentPreviewWindow")
    }
}
@MainActor private final class OverlayState: ObservableObject {
    @Published var expanded = false
    var closing = false
    let size: CGSize
    init(url: URL) { size = AttachmentPreviewGeometry.size(url) }
}
private struct PreviewOverlay: View {
    let url: URL
    let source: CGRect?
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var state: OverlayState
    init(url: URL, source: CGRect?, close: @escaping () -> Void) {
        self.url = url; self.source = source; self.close = close
        _state = StateObject(wrappedValue: OverlayState(url: url))
    }
    var body: some View {
        GeometryReader { proxy in
            let target = AttachmentPreviewGeometry.fit(size: state.size, in: proxy.size)
            let rect = state.expanded ? target : (source ?? target)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(state.expanded ? 0.72 : 0).contentShape(Rectangle()).onTapGesture { dismiss() }
                AttachmentPreview(url: url, onClose: dismiss).frame(width: max(1, rect.width), height: max(1, rect.height)).position(x: rect.midX, y: rect.midY)
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭附件预览").help("关闭预览（Esc）")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
            }.onAppear { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { state.expanded = true } }
        }.accessibilityAddTraits(.isModal)
    }
    private func dismiss() {
        guard !state.closing else { return }; state.closing = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { state.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.18)) { close() }
    }
}
enum AttachmentPreviewGeometry {
    static func fit(size: CGSize, in window: CGSize) -> CGRect {
        let scale = min(max(1, window.width - 64) / max(1, size.width), max(1, window.height - 64) / max(1, size.height))
        let fitted = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        return CGRect(x: (window.width - fitted.width) / 2, y: (window.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
    static func size(_ url: URL) -> CGSize {
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url), let page = document.page(at: 0) { return page.bounds(for: .cropBox).size }
        return NSImage(contentsOf: url)?.size ?? CGSize(width: 500, height: 400)
    }
}
struct AttachmentPreview: View {
    let url: URL
    let onClose: () -> Void
    var body: some View {
        if url.pathExtension.lowercased() == "pdf" { AttachmentPDF(url: url, close: onClose) }
        else if let image = NSImage(contentsOf: url) { AttachmentImage(image: image, close: onClose) }
        else {
            VStack(spacing: 12) {
                Image(systemName: "doc").font(.largeTitle)
                Text("无法预览 \(url.pathExtension.uppercased()) 文件")
                Text("文件可能已移除或格式暂不支持").font(.caption)
            }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()).onTapGesture(perform: onClose)
        }
    }
}
private final class PreviewImageView: NSImageView {
    var close: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { close(); return }
        if scroll.magnification > 1.01 { scroll.setMagnification(1, centeredAt: convert(event.locationInWindow, from: nil)) } else { close() }
    }
}
private final class PreviewScrollView: NSScrollView {
    override func layout() { super.layout(); if magnification <= 1.01 { documentView?.frame = CGRect(origin: .zero, size: contentSize) } }
}
private struct AttachmentImage: NSViewRepresentable {
    let image: NSImage
    let close: () -> Void
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PreviewScrollView()
        scroll.drawsBackground = false; scroll.allowsMagnification = true; scroll.minMagnification = 1; scroll.maxMagnification = 8
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = PreviewImageView(); view.imageScaling = .scaleProportionallyUpOrDown; view.image = image; view.close = close
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? PreviewImageView else { return }; view.image = image; view.close = close
        if scroll.magnification <= 1.01 { view.frame = CGRect(origin: .zero, size: scroll.contentSize) }
    }
}
private final class PreviewPDFView: PDFView {
    var close: () -> Void = {}
    override init(frame: NSRect) {
        super.init(frame: frame)
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delaysPrimaryMouseButtonEvents = true
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    @objc private func clicked() {
        if scaleFactor > scaleFactorForSizeToFit * 1.02 { autoScales = true; scaleFactor = scaleFactorForSizeToFit } else { close() }
    }
}
@MainActor private final class PDFState: ObservableObject {
    @Published var page = 0
    let document: PDFDocument?
    init(url: URL) { document = PDFDocument(url: url) }
}
private struct AttachmentPDF: View {
    let url: URL
    let close: () -> Void
    @StateObject private var state: PDFState
    init(url: URL, close: @escaping () -> Void) {
        self.url = url; self.close = close
        _state = StateObject(wrappedValue: PDFState(url: url))
    }
    private var count: Int { state.document?.pageCount ?? 0 }
    var body: some View {
        VStack(spacing: 8) {
            if let document = state.document { PDFCanvas(document: document, page: state.page, close: close) }
            else { Text("无法读取 PDF 文件").foregroundStyle(.white).onTapGesture(perform: close) }
            if count > 1 {
                HStack {
                    Button { state.page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(state.page == 0).help("上一页")
                    Text("\(state.page + 1) / \(count)").monospacedDigit().foregroundStyle(.white)
                    Button { state.page += 1 } label: { Image(systemName: "chevron.right") }.disabled(state.page + 1 >= count).help("下一页")
                }.buttonStyle(.borderless)
            }
        }
    }
}
private struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let close: () -> Void
    func makeNSView(context: Context) -> PreviewPDFView {
        let view = PreviewPDFView(); view.document = document; view.displayMode = .singlePage; view.autoScales = true; view.backgroundColor = .clear; view.close = close
        return view
    }
    func updateNSView(_ view: PreviewPDFView, context: Context) {
        view.close = close
        if let target = view.document?.page(at: page), view.currentPage !== target { view.go(to: target); view.autoScales = true }
    }
}
