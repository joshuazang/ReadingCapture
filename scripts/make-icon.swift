import AppKit
import Foundation

let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: image)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
    NSColor(srgbRed: 0.13, green: 0.37, blue: 0.32, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 200, yRadius: 200).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 260, y: 200, width: 504, height: 624), xRadius: 54, yRadius: 54).fill()
    NSColor(srgbRed: 0.13, green: 0.37, blue: 0.32, alpha: 1).setStroke()
    for y in [660, 530, 400] {
        let line = NSBezierPath(); line.lineWidth = 38; line.lineCapStyle = .round
        line.move(to: NSPoint(x: 340, y: CGFloat(y))); line.line(to: NSPoint(x: y == 400 ? 550 : 680, y: CGFloat(y))); line.stroke()
    }
    NSColor(srgbRed: 0.97, green: 0.73, blue: 0.28, alpha: 1).setFill()
    let marker = NSBezierPath(); marker.move(to: NSPoint(x: 635, y: 824)); marker.line(to: NSPoint(x: 710, y: 824)); marker.line(to: NSPoint(x: 710, y: 615)); marker.line(to: NSPoint(x: 672, y: 650)); marker.line(to: NSPoint(x: 635, y: 615)); marker.close(); marker.fill()
    NSGraphicsContext.restoreGraphicsState()
    try image.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(name + ".png"))
}
