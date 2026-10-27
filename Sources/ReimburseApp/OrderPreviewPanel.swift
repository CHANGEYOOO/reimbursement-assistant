import AppKit
import SwiftUI

struct OrderPreviewPanel: View {
    let expense: Expense?
    let enlarge: (URL) -> Void
    let close: () -> Void
    @StateObject private var controls = PreviewZoomControls()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(expense.map { "第 \($0.number) 笔截图" } ?? "截图预览").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("收起截图预览")
            }
            if let expense {
                Text(expense.sourceURL.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Button { controls.zoom = max(1, controls.zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(controls.zoom <= 1).help("缩小")
                    Button("\(Int(controls.zoom * 100))%") { controls.zoom = 1 }.help("恢复适合宽度")
                    Button { controls.zoom = min(3, controls.zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(controls.zoom >= 3).help("放大")
                    Spacer()
                }
                GeometryReader { geometry in
                    if let image = NSImage(contentsOf: expense.sourceURL), image.size.width > 0 {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: max(1, geometry.size.width - 16) * controls.zoom)
                                .onTapGesture { enlarge(expense.sourceURL) }
                                .attachmentPreviewSource(url: expense.sourceURL)
                                .accessibilityLabel("点击放大第\(expense.number)笔截图")
                                .padding(8)
                        }
                        .id(expense.id)
                    } else {
                        Text("无法显示图片").foregroundStyle(.secondary)
                    }
                }
                Text("滚动查看长图，点击图片可放大")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                Text("选择一条订单，在这里查看截图")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .onChange(of: expense?.id) { _, _ in controls.zoom = 1 }
    }
}

@MainActor private final class PreviewZoomControls: ObservableObject {
    @Published var zoom = 1.0
}
