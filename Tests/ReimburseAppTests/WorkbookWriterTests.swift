import AppKit
import Foundation
import Dispatch
#if canImport(ReimburseApp)
import ReimburseApp
#endif
#if canImport(XCTest)
import XCTest
#endif

private enum WorkbookChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "WorkbookWriterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func makePNG(at url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.red, atX: 0, y: 0)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "png", code: 1) }
        try data.write(to: url)
    }

    static func unzipText(_ file: URL, _ entry: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", file.path, entry == "[Content_Types].xml" ? "\\[Content_Types\\].xml" : entry]
        let output = Pipe()
        task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        try check(task.terminationStatus == 0, "xlsx must contain \(entry)")
        return String(decoding: data, as: UTF8.self)
    }

    static func zipEntries(_ file: URL) throws -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-Z1", file.path]
        let output = Pipe()
        task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        try check(task.terminationStatus == 0, "xlsx must be a valid zip")
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func exportStructure() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("sample.png")
        try makePNG(at: image)
        var expenses = [
            Expense(number: 1, sourceURL: image, amount: Decimal(string: "44.26"), purpose: "交通"),
            Expense(number: 2, sourceURL: image, amount: Decimal(string: "86.03"), purpose: "餐食"),
            Expense(number: 3, sourceURL: image, amount: Decimal(string: "22.80"), purpose: "住宿"),
        ]
        expenses[0].date = "2026-09-21"
        expenses[1].date = ""
        expenses[2].date = "2026-09-23"
        let output = folder.appendingPathComponent("result.xlsx")
        try WorkbookWriter.write(title: "测试报销单", expenses: expenses, to: output)
        let sheet = try unzipText(output, "xl/worksheets/sheet1.xml")
        let drawing = try unzipText(output, "xl/drawings/drawing1.xml")
        let drawingRels = try unzipText(output, "xl/drawings/_rels/drawing1.xml.rels")
        let workbook = try unzipText(output, "xl/workbook.xml")
        try check(workbook.contains("测试报销单"), "title should appear as sheet name")
        try check(sheet.contains("<c r=\"A2\" s=\"1\" t=\"inlineStr\"><is><t>序号</t></is></c><c r=\"B2\" s=\"1\" t=\"inlineStr\"><is><t>日期</t></is></c><c r=\"C2\" s=\"1\" t=\"inlineStr\"><is><t>名称</t></is></c><c r=\"D2\" s=\"1\" t=\"inlineStr\"><is><t>图片</t></is></c><c r=\"E2\" s=\"1\" t=\"inlineStr\"><is><t>金额</t></is></c>"), "headers must follow the confirmed five-column order")
        try check(sheet.contains("<c r=\"B3\" s=\"1\" t=\"inlineStr\"><is><t>2026-09-21</t></is></c>"), "recognized date must appear in B3")
        try check(sheet.contains("<c r=\"B4\" s=\"1\" t=\"inlineStr\"><is><t></t></is></c>"), "unknown date must remain blank in B4")
        try check(sheet.contains("<c r=\"B5\" s=\"1\" t=\"inlineStr\"><is><t>2026-09-23</t></is></c>"), "edited date must appear in B5")
        try check(sheet.contains("<c r=\"E3\"") && sheet.contains("<v>44.26</v>"), "first amount must be numeric in E3")
        try check(sheet.contains("<c r=\"E4\"") && sheet.contains("<v>86.03</v>"), "second amount must be numeric in E4")
        try check(sheet.contains("<c r=\"E5\"") && sheet.contains("<v>22.8</v>"), "third amount must be numeric in E5")
        try check(sheet.contains("<f>SUM(E3:E5)</f>"), "total must be a formula in E6")
        try check(sheet.contains("<dimension ref=\"A1:E6\"") && sheet.contains("<mergeCell ref=\"A1:E1\""), "sheet width and title must span five columns")
        try check(sheet.contains("<v>153.09</v>"), "cached total must independently equal 153.09")
        try check(sheet.contains("pageSetup") && sheet.contains("printOptions"), "print settings must exist")
        try check(drawing.components(separatedBy: "<xdr:oneCellAnchor>").count - 1 == 3, "three image anchors")
        try check(drawing.components(separatedBy: "<xdr:col>3</xdr:col>").count - 1 == 3, "images must anchor in column D")
        try check(drawingRels.components(separatedBy: "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\"").count - 1 == 3, "three image relationships")
        let media = try zipEntries(output).filter { $0.hasPrefix("xl/media/") }
        try check(media.count == 3, "three embedded images")
    }

    static func invalidExpense() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("sample.png")
        try makePNG(at: image)
        for expense in [
            Expense(number: 1, sourceURL: image, amount: nil, purpose: "交通"),
            Expense(number: 1, sourceURL: image, amount: 0, purpose: "交通"),
            Expense(number: 1, sourceURL: image, amount: 1, purpose: "   "),
        ] {
            let output = folder.appendingPathComponent("invalid.xlsx")
            var rejected = false
            do { try WorkbookWriter.write(title: "测试", expenses: [expense], to: output) }
            catch { rejected = true }
            try check(rejected, "invalid item must be rejected")
            try check(!FileManager.default.fileExists(atPath: output.path), "invalid item must not create a workbook")
        }
    }
    static func convertsUnsupportedWorkbookImageFormat() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = folder.appendingPathComponent("source.png")
        let tiff = folder.appendingPathComponent("source.tiff")
        try makePNG(at: png)
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: png))!
        try bitmap.representation(using: .tiff, properties: [:])!.write(to: tiff)
        let output = folder.appendingPathComponent("converted.xlsx")
        try WorkbookWriter.write(title: "转换", expenses: [Expense(number: 1, sourceURL: tiff, amount: 1, purpose: "测试")], to: output)
        let entries = try zipEntries(output)
        try check(entries.contains("xl/media/image1.png"), "non-Excel image format should be embedded as PNG")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", output.path, "xl/media/image1.png"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        try check(task.terminationStatus == 0 && bytes.starts(with: [137, 80, 78, 71]), "embedded image should contain PNG data")
    }

    static func existingDestination() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("sample.png")
        try makePNG(at: image)
        let output = folder.appendingPathComponent("existing.xlsx")
        try Data("keep me".utf8).write(to: output)
        var rejected = false
        do { try WorkbookWriter.write(title: "测试", expenses: [Expense(number: 1, sourceURL: image, amount: 1, purpose: "用途")], to: output) }
        catch { rejected = true }
        try check(rejected, "existing destination must be rejected")
        let saved = try Data(contentsOf: output)
        try check(saved == Data("keep me".utf8), "existing destination must remain unchanged")
    }

    static func renamedImagesUseContentType() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("sample.png")
        try makePNG(at: original)
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: original))!
        let tiff = bitmap.representation(using: .tiff, properties: [:])!
        let fakeJPEG = folder.appendingPathComponent("fake.jpg")
        let fakePNG = folder.appendingPathComponent("fake.png")
        try tiff.write(to: fakeJPEG)
        try tiff.write(to: fakePNG)
        let output = folder.appendingPathComponent("renamed.xlsx")
        let items = [Expense(number: 1, sourceURL: fakeJPEG, amount: 1, purpose: "A"),
                     Expense(number: 2, sourceURL: fakePNG, amount: 2, purpose: "B")]
        try WorkbookWriter.write(title: "格式", expenses: items, to: output)
        let entries = try zipEntries(output)
        try check(entries.contains("xl/media/image1.png") && entries.contains("xl/media/image2.png"), "renamed TIFF images must be PNG")
        let embedded = try unzipText(output, "[Content_Types].xml")
        try check(!embedded.contains("Extension=\"jpg\""), "renamed TIFF must not declare JPEG media")
        for name in ["xl/media/image1.png", "xl/media/image2.png"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            task.arguments = ["-p", output.path, name]
            let pipe = Pipe()
            task.standardOutput = pipe
            try task.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            try check(task.terminationStatus == 0 && bytes.starts(with: [137, 80, 78, 71]), "renamed image payload must truly be PNG")
        }
    }

    static func concurrentWritersDoNotOverwrite() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("sample.png")
        try makePNG(at: image)
        let output = folder.appendingPathComponent("raced.xlsx")
        let expense = Expense(number: 1, sourceURL: image, amount: 1, purpose: "用途")
        let lock = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            do {
                try WorkbookWriter.write(title: "竞态\(index)", expenses: [expense], to: output)
                lock.lock(); successes += 1; lock.unlock()
            } catch { }
        }
        try check(successes == 1, "exactly one concurrent writer may claim a destination")
        let entries = try zipEntries(output)
        try check(entries.contains("xl/workbook.xml"), "winning file must be complete")
    }

    static func xmlTextAndSheetName() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("sample.png")
        try makePNG(at: image)
        let invalid = folder.appendingPathComponent("invalid-text.xlsx")
        for (title, purpose) in [("含\u{0001}标题", "用途"), ("标题", "含\u{0002}用途")] {
            var rejected = false
            do { try WorkbookWriter.write(title: title, expenses: [Expense(number: 1, sourceURL: image, amount: 1, purpose: purpose)], to: invalid) }
            catch { rejected = true }
            try check(rejected, "XML control character must be rejected")
            try check(!FileManager.default.fileExists(atPath: invalid.path), "invalid XML text must not create a workbook")
        }
        let output = folder.appendingPathComponent("long-title.xlsx")
        try WorkbookWriter.write(title: String(repeating: "😀", count: 20),
            expenses: [Expense(number: 1, sourceURL: image, amount: 1, purpose: "用途")], to: output)
        let workbook = try unzipText(output, "xl/workbook.xml")
        try check(workbook.contains("name=\"\(String(repeating: "😀", count: 15))\""), "sheet name must fit 31 UTF-16 units")
        let named = folder.appendingPathComponent("sanitized-name.xlsx")
        try WorkbookWriter.write(title: "'A\nB/[C]'", expenses: [Expense(number: 1, sourceURL: image, amount: 1, purpose: "用途")], to: named)
        let renamed = try unzipText(named, "xl/workbook.xml")
        try check(renamed.contains("name=\"_A_B__C__\""), "worksheet name must exclude forbidden characters and edge apostrophes")
    }

    static func confirmedOverwrite() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("sample.png")
        try makePNG(at: image)
        let output = folder.appendingPathComponent("confirmed.xlsx")
        try Data("old synthetic content".utf8).write(to: output)
        try WorkbookWriter.write(title: "新报销单", expenses: [Expense(number: 1, sourceURL: image, amount: 7, purpose: "新用途")],
            to: output, overwriteConfirmed: true)
        let sheet = try unzipText(output, "xl/worksheets/sheet1.xml")
        try check(sheet.contains("新用途") && sheet.contains("<v>7</v>"), "confirmed overwrite must replace old bytes with new workbook")
        let workbook = try unzipText(output, "xl/workbook.xml")
        try check(workbook.contains("新报销单"), "confirmed overwrite must contain new title")
    }

    static func emptyBatch() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd").appendingPathComponent("workbook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("empty.xlsx")
        var rejected = false
        do { try WorkbookWriter.write(title: "测试", expenses: [], to: output) }
        catch { rejected = true }
        try check(rejected, "empty batch must be rejected")
        try check(!FileManager.default.fileExists(atPath: output.path), "empty batch must not create a workbook")
    }

}

#if canImport(XCTest)
final class WorkbookWriterTests: XCTestCase {
    func testExportStructure() throws { try WorkbookChecks.exportStructure() }
    func testInvalidExpense() throws { try WorkbookChecks.invalidExpense() }
    func testEmptyBatch() throws { try WorkbookChecks.emptyBatch() }
    func testConvertsUnsupportedWorkbookImageFormat() throws { try WorkbookChecks.convertsUnsupportedWorkbookImageFormat() }
    func testExistingDestination() throws { try WorkbookChecks.existingDestination() }
    func testConfirmedOverwrite() throws { try WorkbookChecks.confirmedOverwrite() }
    func testRenamedImagesUseContentType() throws { try WorkbookChecks.renamedImagesUseContentType() }
    func testConcurrentWritersDoNotOverwrite() throws { try WorkbookChecks.concurrentWritersDoNotOverwrite() }
    func testXMLTextAndSheetName() throws { try WorkbookChecks.xmlTextAndSheetName() }
}
#endif

#if DIRECT_TEST_RUNNER
@main struct RunWorkbookChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--rename") { try WorkbookChecks.renamedImagesUseContentType(); return }
        if CommandLine.arguments.contains("--race") { try WorkbookChecks.concurrentWritersDoNotOverwrite(); return }
        if CommandLine.arguments.contains("--xml") { try WorkbookChecks.xmlTextAndSheetName(); return }
        try WorkbookChecks.exportStructure()
        try WorkbookChecks.invalidExpense()
        try WorkbookChecks.emptyBatch()
        try WorkbookChecks.convertsUnsupportedWorkbookImageFormat()
        try WorkbookChecks.existingDestination()
        try WorkbookChecks.confirmedOverwrite()
        try WorkbookChecks.renamedImagesUseContentType()
        try WorkbookChecks.concurrentWritersDoNotOverwrite()
        try WorkbookChecks.xmlTextAndSheetName()
        print("WorkbookWriter checks passed")
    }
}
#endif
