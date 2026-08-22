import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make_icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let side: CGFloat = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side),
    pixelsHigh: Int(side),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
bitmap.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }
context.imageInterpolation = .high

let canvas = NSRect(x: 32, y: 32, width: 960, height: 960)
let background = NSBezierPath(roundedRect: canvas, xRadius: 215, yRadius: 215)
let gradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.16, green: 0.11, blue: 0.36, alpha: 1), 0),
    (NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.72, alpha: 1), 0.52),
    (NSColor(calibratedRed: 0.16, green: 0.58, blue: 0.89, alpha: 1), 1)
)!
gradient.draw(in: background, angle: -45)

NSColor.white.withAlphaComponent(0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: 128, y: 290, width: 768, height: 768)).fill()

let lens = NSBezierPath(ovalIn: NSRect(x: 260, y: 330, width: 390, height: 390))
lens.lineWidth = 74
lens.lineCapStyle = .round
NSColor.white.setStroke()
lens.stroke()

let handle = NSBezierPath()
handle.move(to: NSPoint(x: 625, y: 355))
handle.line(to: NSPoint(x: 790, y: 190))
handle.lineWidth = 82
handle.lineCapStyle = .round
handle.stroke()

let spark = NSBezierPath()
spark.move(to: NSPoint(x: 650, y: 790))
spark.curve(to: NSPoint(x: 700, y: 740), controlPoint1: NSPoint(x: 678, y: 790), controlPoint2: NSPoint(x: 700, y: 768))
spark.curve(to: NSPoint(x: 750, y: 790), controlPoint1: NSPoint(x: 700, y: 768), controlPoint2: NSPoint(x: 722, y: 790))
spark.curve(to: NSPoint(x: 700, y: 840), controlPoint1: NSPoint(x: 722, y: 790), controlPoint2: NSPoint(x: 700, y: 812))
spark.curve(to: NSPoint(x: 650, y: 790), controlPoint1: NSPoint(x: 700, y: 812), controlPoint2: NSPoint(x: 678, y: 790))
spark.close()
NSColor.white.setFill()
spark.fill()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
