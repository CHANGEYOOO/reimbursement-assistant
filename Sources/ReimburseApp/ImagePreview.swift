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
            } else {
                Spacer()
                Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.secondary)
                Text("选择附件，在这里查看内容").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
        }.padding(12).background(.quaternary.opacity(0.3))
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
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: max(1, geometry.size.width - 16) * state.zoom).padding(8)
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
private struct SidePDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let zoom: Double
    let reset: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var page = -1; var zoom = -1.0; var reset = -1 }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .clear
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.page != page, let target = document.page(at: page) {
            view.go(to: target)
            context.coordinator.page = page
        }
        if context.coordinator.zoom != zoom || context.coordinator.reset != reset {
            view.autoScales = zoom == 1
            view.scaleFactor = view.scaleFactorForSizeToFit * zoom
            context.coordinator.zoom = zoom
            context.coordinator.reset = reset
        }
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
}
#endif
