#!/usr/bin/env swift
// Draws the app icon and writes Resources/AppIcon.icns.
//
//   swift make-icon.swift            write the .icns
//   swift make-icon.swift preview.png   also write the 1024px master, to look at
//
// The icon is drawn in code rather than kept as an image so that it can be changed
// by editing numbers, and so the repository holds the source and not only the output.
// Two screens at different heights, joined by a gangway.
import AppKit

/// Everything is laid out on a 1024-point canvas with y up, then scaled to each size.
func draw(in ctx: CGContext, size: CGFloat) {
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    let rgb = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: rgb, components: [CGFloat((hex >> 16) & 0xFF) / 255,
                                              CGFloat((hex >> 8) & 0xFF) / 255,
                                              CGFloat(hex & 0xFF) / 255, alpha])!
    }

    // The plate. Apple's grid: an 824-point rounded square centred on the canvas,
    // leaving room around it for the shadow.
    let plate = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(plate)
    ctx.setFillColor(color(0x0D3B66))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let sea = CGGradient(colorsSpace: rgb,
                         colors: [color(0x3FB8E0), color(0x1B6CA8), color(0x0B2F5B)] as CFArray,
                         locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(sea, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100),
                           options: [])
    ctx.restoreGState()

    // The two screens: a white bezel around a pale display.
    func screen(_ frame: CGRect) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.25))
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 34, cornerHeight: 34, transform: nil))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 22, dy: 22),
                           cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.setFillColor(color(0xCFE8F5))
        ctx.fillPath()
    }
    screen(CGRect(x: 178, y: 236, width: 320, height: 220))
    screen(CGRect(x: 526, y: 568, width: 320, height: 220))

    // The gangway: a deck, a handrail parallel to it, and stanchions between.
    let low = CGPoint(x: 338, y: 388), high = CGPoint(x: 686, y: 636)
    let railRise: CGFloat = 104
    func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat) {
        ctx.setLineWidth(width)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x000000, 0.3))
    ctx.setStrokeColor(color(0x0A0A0A))
    ctx.setLineCap(.round)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    line(low, high, width: 48)
    line(CGPoint(x: low.x, y: low.y + railRise), CGPoint(x: high.x, y: high.y + railRise), width: 22)
    for step in 0...3 {
        let t = CGFloat(step) / 3
        let foot = CGPoint(x: low.x + (high.x - low.x) * t, y: low.y + (high.y - low.y) * t)
        line(foot, CGPoint(x: foot.x, y: foot.y + railRise), width: 20)
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    draw(in: ctx, size: CGFloat(size))
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("Gangway-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// iconutil wants each point size at 1x and 2x, under these exact names.
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icns.path)")

if CommandLine.arguments.count > 1 {
    try png(size: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("Wrote \(CommandLine.arguments[1])")
}
