#if DIRECT_TEST_RUNNER
import AppKit
import PDFKit

func checkAttachmentThumbnails() async throws {
    checkAttachmentPreviewGeometry()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-preview-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let image = NSImage(size: CGSize(width: 300, height: 150))
    image.lockFocus(); NSColor.red.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 300, height: 150)).fill(); image.unlockFocus()
    let imageURL = folder.appendingPathComponent("sample.tiff")
    try image.tiffRepresentation!.write(to: imageURL)
    let cache = AttachmentThumbnailCache()
    let first = await cache.thumbnail(imageURL)
    assert(first != nil)
    let cached = await cache.thumbnail(imageURL)
    assert(first == cached)
    let pdf = PDFDocument(); pdf.insert(PDFPage(image: image)!, at: 0); pdf.insert(PDFPage(image: image)!, at: 1)
    let pdfURL = folder.appendingPathComponent("sample.pdf")
    assert(pdf.write(to: pdfURL))
    let pdfData = await cache.thumbnail(pdfURL)
    assert(pdfData != nil)
    let missing = await cache.thumbnail(folder.appendingPathComponent("missing.pdf"))
    assert(missing == nil)
    try Data("unsupported".utf8).write(to: imageURL)
    let replaced = await cache.thumbnail(imageURL)
    assert(replaced == nil)
    // Test fixtures stay in the temporary folder; no user data is read or deleted.
}
#endif
