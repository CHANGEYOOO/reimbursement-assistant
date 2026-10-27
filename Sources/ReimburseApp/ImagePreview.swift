import AppKit
import Combine
import PDFKit
import SwiftUI

struct AttachmentSidePreview: View {
    let url: URL?
    let title: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("收起附件预览")
                    .accessibilityLabel("收起附件预览")
            }
            if let url {
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                AttachmentSideContent(url: url).id(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.secondary)
                Text("选择附件，在这里查看内容").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12).background(.quaternary.opacity(0.3))
    }
}
@MainActor private final class SidePreviewState: ObservableObject {
    @Published var zoom = 1.0
    @Published var page = 0
    @Published var reset = 0
    var gestureStartZoom = 1.0
    let image: NSImage?
    let document: PDFDocument?
    init(url: URL) {
        if url.pathExtension.lowercased() == "pdf" { document = PDFDocument(url: url); image = nil }
        else { document = nil; image = NSImage(contentsOf: url) }
    }
    func setZoom(_ value: Double) { zoom = min(8, max(1, value)); gestureStartZoom = zoom }
}
private struct AttachmentSideContent: View {
    let url: URL
    @StateObject private var state: SidePreviewState
    init(url: URL) {
        self.url = url
        _state = StateObject(wrappedValue: SidePreviewState(url: url))
    }
    var body: some View {
        VStack(spacing: 10) {
            if state.image != nil || state.document != nil {
                HStack {
                    Button { state.setZoom(state.zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(state.zoom <= 1).help("缩小")
                    Button("\(Int(state.zoom * 100))%") { state.setZoom(1); state.reset += 1 }.help("恢复适合宽度")
                    Button { state.setZoom(state.zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(state.zoom >= 8).help("放大")
                    Spacer()
                }
            }
            if let document = state.document {
                SidePDFCanvas(document: document, page: state.page, zoom: state.zoom, reset: state.reset)
                if document.pageCount > 1 {
                    HStack {
                        Button { state.page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(state.page == 0).help("上一页")
                        Text("\(state.page + 1) / \(document.pageCount)").monospacedDigit()
                        Button { state.page += 1 } label: { Image(systemName: "chevron.right") }.disabled(state.page + 1 >= document.pageCount).help("下一页")
                    }.buttonStyle(.borderless)
                }
            } else if let image = state.image, image.size.width > 0 {
                GeometryReader { geometry in
                    let size = SidePreviewSizing.image(image.size, availableWidth: geometry.size.width, zoom: state.zoom)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable()
                            .frame(width: size.width, height: size.height).padding(8)
                            .gesture(MagnifyGesture().onChanged { value in
                                state.zoom = min(8, max(1, state.gestureStartZoom * value.magnification))
                            }.onEnded { _ in state.gestureStartZoom = state.zoom })
                            .accessibilityLabel("附件图片")
                    }
                }
            } else {
                Spacer()
                Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
                Text("无法预览 \(url.pathExtension.uppercased()) 文件").foregroundStyle(.secondary)
                Text("文件可能已移除或格式暂不支持").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if state.image != nil || state.document != nil {
                Text("滚动查看内容，使用上方按钮缩放").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
enum SidePreviewSizing {
    static func widthScale(pageWidth: CGFloat, availableWidth: CGFloat, zoom: Double) -> CGFloat {
        max(1, availableWidth - 16) / max(1, pageWidth) * zoom
    }
    static func pageWidth(_ size: CGSize, rotation: Int) -> CGFloat {
        abs(rotation % 180) == 90 ? size.height : size.width
    }
    static func image(_ size: CGSize, availableWidth: CGFloat, zoom: Double) -> CGSize {
        let scale = widthScale(pageWidth: size.width, availableWidth: availableWidth, zoom: zoom)
        return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }
}
private final class WidthFittingPDFView: PDFView {
    var requestedZoom = 1.0
    var needsWidthFit = true
    private var fittedWidth: CGFloat = 0
    override func layout() {
        super.layout()
        guard bounds.width > 16, let page = currentPage,
              needsWidthFit || abs(fittedWidth - bounds.width) > 0.5 else { return }
        fittedWidth = bounds.width
        needsWidthFit = false
        // Fit after AppKit has a real viewport; PDFView.autoScales fits the entire tall page instead.
        let pageWidth = SidePreviewSizing.pageWidth(page.bounds(for: displayBox).size, rotation: page.rotation)
        let scale = SidePreviewSizing.widthScale(pageWidth: pageWidth, availableWidth: bounds.width, zoom: requestedZoom)
        minScaleFactor = min(minScaleFactor, scale)
        maxScaleFactor = max(maxScaleFactor, scale)
        if abs(scaleFactor - scale) > 0.001 { scaleFactor = scale }
    }
}
private struct SidePDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let zoom: Double
    let reset: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var page = -1; var zoom = -1.0; var reset = -1 }
    func makeNSView(context: Context) -> WidthFittingPDFView {
        let view = WidthFittingPDFView()
        view.document = document
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displayBox = .cropBox
        view.displaysPageBreaks = false
        view.autoScales = false
        view.backgroundColor = .clear
        return view
    }
    func updateNSView(_ view: WidthFittingPDFView, context: Context) {
        if context.coordinator.page != page, let target = document.page(at: page) {
            view.go(to: target)
            context.coordinator.page = page
            view.needsWidthFit = true
        }
        if context.coordinator.zoom != zoom || context.coordinator.reset != reset {
            view.requestedZoom = zoom
            view.needsWidthFit = true
            context.coordinator.zoom = zoom
            context.coordinator.reset = reset
        }
        view.needsLayout = true
    }
}

#if DIRECT_TEST_RUNNER
@MainActor func checkAttachmentSidebarState(imageURL: URL, pdfURL: URL) {
    let first = SidePreviewState(url: imageURL)
    assert(first.image != nil && first.document == nil)
    first.setZoom(99); assert(first.zoom == 8)
    first.setZoom(-1); assert(first.zoom == 1)
    first.setZoom(2); first.page = 1
    let next = SidePreviewState(url: pdfURL)
    assert(next.zoom == 1 && next.page == 0 && next.document?.pageCount == 2)
    assert(next.image == nil)
    let long = CGSize(width: 400, height: 4000)
    let fit = SidePreviewSizing.image(long, availableWidth: 616, zoom: 1)
    assert(fit == CGSize(width: 600, height: 6000))
    assert(SidePreviewSizing.image(long, availableWidth: 816, zoom: 2) == CGSize(width: 1600, height: 16000))
    assert(SidePreviewSizing.widthScale(pageWidth: 400, availableWidth: 616, zoom: 1) == 1.5)
    let canvas = WidthFittingPDFView(frame: NSRect(x: 0, y: 0, width: 616, height: 400))
    canvas.document = next.document
    canvas.autoScales = false
    canvas.layout()
    let pageWidth = canvas.currentPage!.bounds(for: canvas.displayBox).width
    assert(abs(canvas.scaleFactor - 600 / pageWidth) < 0.001)
    canvas.setFrameSize(NSSize(width: 816, height: 400)); canvas.layout()
    assert(abs(canvas.scaleFactor - 800 / pageWidth) < 0.001)
    canvas.requestedZoom = 2; canvas.needsWidthFit = true; canvas.layout()
    assert(abs(canvas.scaleFactor - 1600 / pageWidth) < 0.001)
    let sample = CGSize(width: 300, height: 600)
    assert(SidePreviewSizing.pageWidth(sample, rotation: 0) == 300)
    for rotation in [90, 270, -90] { assert(SidePreviewSizing.pageWidth(sample, rotation: rotation) == 600) }
    let rotatedPage = canvas.currentPage!
    rotatedPage.rotation = 90
    canvas.requestedZoom = 1; canvas.needsWidthFit = true; canvas.layout()
    let rotatedWidth = rotatedPage.bounds(for: canvas.displayBox).height
    assert(abs(canvas.scaleFactor - 800 / rotatedWidth) < 0.001)
    canvas.requestedZoom = 100; canvas.needsWidthFit = true; canvas.layout()
    assert(abs(canvas.scaleFactor - 80000 / rotatedWidth) < 0.001)
    canvas.setFrameSize(NSSize(width: 17, height: 400))
    canvas.requestedZoom = 1; canvas.needsWidthFit = true; canvas.layout()
    assert(abs(canvas.scaleFactor - 1 / rotatedWidth) < 0.001)
}
#endif
