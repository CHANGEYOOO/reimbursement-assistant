import AppKit

guard CommandLine.arguments.count == 2 else { exit(2) }
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor.systemOrange.setFill()
NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 200, yRadius: 200).fill()
let configuration = NSImage.SymbolConfiguration(paletteColors: [.white])
guard let eye = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { exit(1) }
eye.draw(in: NSRect(x: 170, y: 340, width: 684, height: 400))
let label = "TEST" as NSString
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 116, weight: .heavy), .foregroundColor: NSColor.white]
let size = label.size(withAttributes: attributes)
label.draw(at: NSPoint(x: (1024 - size.width) / 2, y: 175), withAttributes: attributes)
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
