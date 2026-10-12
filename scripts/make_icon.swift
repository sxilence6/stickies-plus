// Draws Resources/AppIcon.icns: a yellow sticky with one ticked and two open boxes.
// Run: swift scripts/make_icon.swift
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
let paper = rgb(0.996, 0.957, 0.612), spine = rgb(0.996, 0.918, 0.239)
let control = rgb(0.859, 0.773, 0.012), ink = rgb(0.18, 0.16, 0.10)

func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    paper.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    spine.setFill()
    NSRect(x: body.minX, y: body.maxY - 118 * s, width: body.width, height: 118 * s).fill()
    // spine buttons, Stickies style
    control.setStroke()
    let w = 9 * s
    let close = NSBezierPath(rect: NSRect(x: body.minX + 150 * s, y: body.maxY - 82 * s, width: 46 * s, height: 46 * s))
    close.lineWidth = w; close.stroke()
    let collapse = NSBezierPath(rect: NSRect(x: body.maxX - 196 * s, y: body.maxY - 82 * s, width: 46 * s, height: 46 * s))
    collapse.move(to: NSPoint(x: body.maxX - 196 * s, y: body.maxY - 50 * s))
    collapse.line(to: NSPoint(x: body.maxX - 150 * s, y: body.maxY - 50 * s))
    collapse.lineWidth = w; collapse.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let rows: [(CGFloat, Bool, CGFloat)] = [(610, true, 330), (450, false, 400), (290, false, 270)]
    for (y, ticked, length) in rows {
        let box = NSRect(x: 230 * s, y: (y - 50) * s, width: 100 * s, height: 100 * s)
        let boxPath = NSBezierPath(roundedRect: box, xRadius: 20 * s, yRadius: 20 * s)
        let line = NSBezierPath(roundedRect: NSRect(x: 385 * s, y: (y - 15) * s, width: length * s, height: 30 * s),
                                xRadius: 15 * s, yRadius: 15 * s)
        if ticked {
            control.setFill(); boxPath.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 24 * s, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 43 * s, y: box.minY + 25 * s))
            check.line(to: NSPoint(x: box.maxX - 22 * s, y: box.maxY - 26 * s))
            check.lineWidth = 15 * s; check.lineCapStyle = .round; check.lineJoinStyle = .round
            NSColor.white.setStroke(); check.stroke()
            ink.withAlphaComponent(0.28).setFill(); line.fill()
        } else {
            control.setStroke(); boxPath.lineWidth = 11 * s; boxPath.stroke()
            ink.withAlphaComponent(0.82).setFill(); line.fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: "Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run(); task.waitUntilExit()
try! draw(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
print(task.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
