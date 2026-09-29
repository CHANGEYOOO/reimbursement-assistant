import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

public enum WorkbookWriter {
    public enum Error: LocalizedError {
        case invalidTitle
        case emptyExpenses
        case invalidText
        case invalidExpense(Int)
        case unsupportedImage(URL)
        case destinationExists

        public var errorDescription: String? {
            switch self {
            case .invalidTitle: "请填写报销单标题。"
            case .emptyExpenses: "请先添加费用记录。"
            case .invalidText: "标题或用途包含无法写入报销单的控制字符。"
            case .invalidExpense(let number): "第\(number)笔费用需要填写正数金额和用途。"
            case .unsupportedImage(let url): "无法读取图片：\(url.lastPathComponent)"
            case .destinationExists: "目标文件已存在，请确认覆盖或另存为。"
            }
        }
    }

    public static func write(title: String, expenses: [Expense], to destination: URL, overwriteConfirmed: Bool = false) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Error.invalidTitle }
        guard !expenses.isEmpty else { throw Error.emptyExpenses }
        guard validXMLText(title), expenses.allSatisfy({ validXMLText($0.purpose) && validXMLText($0.date) }) else { throw Error.invalidText }
        for expense in expenses {
            guard let amount = expense.amount, amount > 0,
                  !expense.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.invalidExpense(expense.number)
            }
        }
        let fm = FileManager.default
        if !overwriteConfirmed && fm.fileExists(atPath: destination.path) { throw Error.destinationExists }
        var parts: [(String, Data)] = []
        var imageNames: [String] = []
        var imageSizes: [(Int, Int)] = []
        for (index, expense) in expenses.enumerated() {
            guard let source = CGImageSourceCreateWithURL(expense.sourceURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Error.unsupportedImage(expense.sourceURL) }
            let contentType = CGImageSourceGetType(source) as String?
            let originalFormat = contentType == UTType.png.identifier ? "png" :
                                 contentType == UTType.jpeg.identifier ? "jpg" : nil
            let name = "image\(index + 1).\(originalFormat ?? "png")"
            let bytes: Data
            if originalFormat != nil {
                bytes = try Data(contentsOf: expense.sourceURL)
            } else {
                let converted = NSMutableData()
                guard let writer = CGImageDestinationCreateWithData(converted as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
                    throw Error.unsupportedImage(expense.sourceURL)
                }
                CGImageDestinationAddImage(writer, image, nil)
                guard CGImageDestinationFinalize(writer) else { throw Error.unsupportedImage(expense.sourceURL) }
                bytes = converted as Data
            }
            parts.append(("xl/media/\(name)", bytes))
            imageNames.append(name)
            imageSizes.append((image.width, image.height))
        }

        let sheetName = safeSheetName(title)
        addXML(contentTypes(hasJPEG: imageNames.contains { $0.hasSuffix(".jpg") }), "[Content_Types].xml", to: &parts)
        addXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """, "_rels/.rels", to: &parts)
        addXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(xml(sheetName.isEmpty ? "报销单" : sheetName))" sheetId="1" r:id="rId1"/></sheets><calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>
            """, "xl/workbook.xml", to: &parts)
        addXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """, "xl/_rels/workbook.xml.rels", to: &parts)
        addXML(styles, "xl/styles.xml", to: &parts)
        addXML(sheet(title: title, expenses: expenses), "xl/worksheets/sheet1.xml", to: &parts)
        addXML("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>
            """, "xl/worksheets/_rels/sheet1.xml.rels", to: &parts)
        addXML(drawing(sizes: imageSizes), "xl/drawings/drawing1.xml", to: &parts)
        let imageRelations = imageNames.enumerated().map { index, name in
            "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/\(name)\"/>"
        }.joined()
        addXML("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(imageRelations)</Relationships>",
                     "xl/drawings/_rels/drawing1.xml.rels", to: &parts)

        let archive = zip(parts)
        let flags = O_WRONLY | O_CREAT | (overwriteConfirmed ? O_TRUNC : O_EXCL)
        let fd = destination.path.withCString { Darwin.open($0, flags, mode_t(0o644)) }
        guard fd >= 0 else {
            if errno == EEXIST { throw Error.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try archive.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if count == 0 { throw POSIXError(.EIO) }
                    offset += count
                }
            }
        } catch {
            _ = Darwin.close(fd)
            throw error // A partial destination may remain after a write failure; no file is deleted.
        }
        if Darwin.close(fd) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func validXMLText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value == 9 || value == 10 || value == 13 ||
                   (value >= 0x20 && value <= 0xD7FF) ||
                   (value >= 0xE000 && value <= 0xFFFD) ||
                   (value >= 0x10000 && value <= 0x10FFFF)
        }
    }

    private static func safeSheetName(_ title: String) -> String {
        var name = ""
        for character in title {
            let value = String(character)
            if name.utf16.count + value.utf16.count > 31 { break }
            let forbidden = value.rangeOfCharacter(from: CharacterSet(charactersIn: "[]:*?/\\")) != nil ||
                            value.unicodeScalars.contains { $0.value < 0x20 }
            name += forbidden ? "_" : value
        }
        if name.hasPrefix("'") { name.replaceSubrange(name.startIndex...name.startIndex, with: "_") }
        if name.hasSuffix("'") { name.replaceSubrange(name.index(before: name.endIndex)..<name.endIndex, with: "_") }
        return name.isEmpty ? "报销单" : name
    }

    private static func addXML(_ value: String, _ path: String, to parts: inout [(String, Data)]) {
        parts.append((path, Data(value.utf8)))
    }

    private static func zip(_ parts: [(String, Data)]) -> Data {
        var result = Data()
        var directory = Data()
        for (name, bytes) in parts {
            let path = Data(name.utf8)
            let crc = crc32(bytes)
            let offset = UInt32(result.count)
            result.appendLE(UInt32(0x04034b50))
            result.appendLE(UInt16(20))
            result.appendLE(UInt16(0x0800))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(33))
            result.appendLE(crc)
            result.appendLE(UInt32(bytes.count))
            result.appendLE(UInt32(bytes.count))
            result.appendLE(UInt16(path.count))
            result.appendLE(UInt16(0))
            result.append(path)
            result.append(bytes)

            directory.appendLE(UInt32(0x02014b50))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(33))
            directory.appendLE(crc)
            directory.appendLE(UInt32(bytes.count))
            directory.appendLE(UInt32(bytes.count))
            directory.appendLE(UInt16(path.count))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt32(0))
            directory.appendLE(offset)
            directory.append(path)
        }
        let directoryOffset = UInt32(result.count)
        result.append(directory)
        result.appendLE(UInt32(0x06054b50))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(parts.count))
        result.appendLE(UInt16(parts.count))
        result.appendLE(UInt32(directory.count))
        result.appendLE(directoryOffset)
        result.appendLE(UInt16(0))
        return result
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        return crc ^ 0xffffffff
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func contentTypes(hasJPEG: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\(hasJPEG ? "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>" : "")<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/></Types>
        """
    }

    private static let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="PingFang SC"/></font><font><b/><sz val="15"/><name val="PingFang SC"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"/><right style="thin"/><top style="thin"/><bottom style="thin"/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="2" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf></cellXfs></styleSheet>
        """

    private static func sheet(title: String, expenses: [Expense]) -> String {
        func textCell(_ ref: String, _ text: String, style: Int) -> String {
            "<c r=\"\(ref)\" s=\"\(style)\" t=\"inlineStr\"><is><t>\(xml(text))</t></is></c>"
        }
        func numberCell(_ ref: String, _ amount: Decimal, style: Int) -> String {
            "<c r=\"\(ref)\" s=\"\(style)\"><v>\(NSDecimalNumber(decimal: amount).stringValue)</v></c>"
        }
        var rows = ["<row r=\"1\" ht=\"38\" customHeight=\"1\">\(textCell("A1", title, style: 0))</row>",
                    "<row r=\"2\" ht=\"26\" customHeight=\"1\">\(textCell("A2", "序号", style: 1))\(textCell("B2", "日期", style: 1))\(textCell("C2", "名称", style: 1))\(textCell("D2", "图片", style: 1))\(textCell("E2", "金额", style: 1))</row>"]
        var total = Decimal.zero
        for (index, expense) in expenses.enumerated() {
            let row = index + 3
            let amount = expense.amount!
            total += amount
            rows.append("<row r=\"\(row)\" ht=\"125\" customHeight=\"1\">\(numberCell("A\(row)", Decimal(expense.number), style: 1))\(textCell("B\(row)", expense.date, style: 1))\(textCell("C\(row)", expense.purpose, style: 2))<c r=\"D\(row)\" s=\"1\"/>\(numberCell("E\(row)", amount, style: 3))</row>")
        }
        let totalRow = expenses.count + 3
        rows.append("<row r=\"\(totalRow)\" ht=\"28\" customHeight=\"1\">\(textCell("A\(totalRow)", "合计", style: 1))<c r=\"B\(totalRow)\" s=\"1\"/><c r=\"C\(totalRow)\" s=\"1\"/><c r=\"D\(totalRow)\" s=\"1\"/><c r=\"E\(totalRow)\" s=\"3\"><f>SUM(E3:E\(totalRow - 1))</f><v>\(NSDecimalNumber(decimal: total).stringValue)</v></c></row>")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetPr><pageSetUpPr fitToPage="1"/></sheetPr><dimension ref="A1:E\(totalRow)"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="18"/><cols><col min="1" max="1" width="8" customWidth="1"/><col min="2" max="2" width="16" customWidth="1"/><col min="3" max="3" width="38" customWidth="1"/><col min="4" max="4" width="35" customWidth="1"/><col min="5" max="5" width="16" customWidth="1"/></cols><sheetData>\(rows.joined())</sheetData><mergeCells count="1"><mergeCell ref="A1:E1"/></mergeCells><printOptions horizontalCentered="1"/><pageMargins left="0.3" right="0.3" top="0.4" bottom="0.4" header="0.2" footer="0.2"/><pageSetup paperSize="9" orientation="portrait" fitToWidth="1" fitToHeight="0"/><drawing r:id="rId1"/></worksheet>
            """
    }

    private static func drawing(sizes: [(Int, Int)]) -> String {
        let anchors = sizes.enumerated().map { index, size -> String in
            let scale = min(225.0 / Double(size.0), 155.0 / Double(size.1), 1.0)
            let width = Int(Double(size.0) * scale * 9525)
            let height = Int(Double(size.1) * scale * 9525)
            return """
                <xdr:oneCellAnchor><xdr:from><xdr:col>3</xdr:col><xdr:colOff>47625</xdr:colOff><xdr:row>\(index + 2)</xdr:row><xdr:rowOff>47625</xdr:rowOff></xdr:from><xdr:ext cx="\(width)" cy="\(height)"/><xdr:pic><xdr:nvPicPr><xdr:cNvPr id="\(index + 1)" name="Image \(index + 1)"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill><a:blip r:embed="rId\(index + 1)"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>
                """
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\(anchors)</xdr:wsDr>"
    }

 }

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
