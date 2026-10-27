import AppKit
import Combine
import ImageIO
import PDFKit
import SwiftUI

actor AttachmentThumbnailCache {
    static let shared = AttachmentThumbnailCache()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    func thumbnail(_ url: URL) -> Data? {
        guard let attributes = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]), let modified = attributes.contentModificationDate else { return nil }
        let key = url.path + "|" + String(modified.timeIntervalSince1970) + "|" + String(attributes.fileSize ?? 0)
        if let data = cache[key] { return data }
        let data: Data?
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url), let page = document.page(at: 0) {
            data = withExtendedLifetime(document) { page.thumbnail(of: CGSize(width: 220, height: 160), for: .cropBox).tiffRepresentation }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 220, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        } else { data = nil }
        guard let data else { return nil }
        // A deleted/replaced attachment must not populate the cache with stale contents.
        guard let current = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]), current.contentModificationDate == modified, current.fileSize == attributes.fileSize else { return nil }
        cache[key] = data; order.append(key)
        while order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
        return data
    }
}
@MainActor private final class ThumbnailState: ObservableObject { @Published var image: NSImage? }
struct AttachmentThumbnail: View {
    let url: URL
    let downloaded: Bool
    @StateObject private var state = ThumbnailState()
    var body: some View {
        Group {
            if let image = state.image { Image(nsImage: image).resizable().scaledToFit() }
            else {
                VStack(spacing: 5) {
                    Image(systemName: downloaded ? "doc" : "icloud.and.arrow.down").font(.title2)
                    Text(downloaded ? url.pathExtension.uppercased() : "待下载").font(.caption)
                }.foregroundStyle(.secondary)
            }
        }.frame(width: 90, height: 70).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
            .task(id: "\(url.path)|\(downloaded)") {
                state.image = nil
                guard downloaded else { return }
                let data = await AttachmentThumbnailCache.shared.thumbnail(url)
                guard !Task.isCancelled else { return }
                state.image = data.flatMap(NSImage.init(data:))
            }
    }
}
