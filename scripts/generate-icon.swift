import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: factor, y: factor)
        let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
        NSColor(calibratedRed: 0.09, green: 0.105, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 204, yRadius: 204).fill()
        let orange = NSColor(calibratedRed: 1, green: 0.64, blue: 0.33, alpha: 1)
        let letters = "LM" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 330, weight: .heavy), .foregroundColor: orange, .kern: -20]
        let textSize = letters.size(withAttributes: attributes)
        letters.draw(at: NSPoint(x: (1024 - textSize.width) / 2 - 10, y: 400), withAttributes: attributes)
        orange.setStroke()
        let flow = NSBezierPath(); flow.lineWidth = 49; flow.lineCapStyle = .round; flow.lineJoinStyle = .round
        flow.move(to: NSPoint(x: 300, y: 310)); flow.line(to: NSPoint(x: 726, y: 310))
        flow.move(to: NSPoint(x: 645, y: 391)); flow.line(to: NSPoint(x: 726, y: 310)); flow.line(to: NSPoint(x: 645, y: 229)); flow.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
