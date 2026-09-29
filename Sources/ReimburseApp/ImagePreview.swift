import SwiftUI

struct ImagePreview: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel("点击图片关闭预览")
            } else {
                Text("无法显示图片").foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
                .padding()
        }
    }
}
