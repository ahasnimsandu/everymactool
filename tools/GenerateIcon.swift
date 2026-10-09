import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments[1]
let size = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { fatalError("No graphics context") }
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let tile = CGPath(roundedRect: bounds.insetBy(dx: 16, dy: 16), cornerWidth: 220, cornerHeight: 220, transform: nil)
context.saveGState()
context.addPath(tile)
context.clip()
let colors = [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.18, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.25, green: 0.26, blue: 0.27, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.15, alpha: 1).cgColor
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.52, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 120, y: 950), end: CGPoint(x: 900, y: 60), options: [])

// Fine glass rings create depth while keeping the silhouette simple at menu-bar scale.
for inset in [86.0, 118.0, 151.0] {
    context.setStrokeColor(NSColor.white.withAlphaComponent(inset == 86 ? 0.13 : 0.055).cgColor)
    context.setLineWidth(inset == 86 ? 3 : 2)
    context.addEllipse(in: bounds.insetBy(dx: inset, dy: inset))
    context.strokePath()
}

// A clean power bolt sits between three small port indicators.
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 555, y: 842))
bolt.addLine(to: CGPoint(x: 374, y: 546))
bolt.addQuadCurve(to: CGPoint(x: 390, y: 516), control: CGPoint(x: 367, y: 526))
bolt.addLine(to: CGPoint(x: 497, y: 516))
bolt.addLine(to: CGPoint(x: 466, y: 252))
bolt.addQuadCurve(to: CGPoint(x: 505, y: 225), control: CGPoint(x: 471, y: 222))
bolt.addLine(to: CGPoint(x: 677, y: 514))
bolt.addQuadCurve(to: CGPoint(x: 659, y: 545), control: CGPoint(x: 686, y: 535))
bolt.addLine(to: CGPoint(x: 554, y: 545))
bolt.addLine(to: CGPoint(x: 590, y: 814))
bolt.addQuadCurve(to: CGPoint(x: 555, y: 842), control: CGPoint(x: 589, y: 848))
bolt.closeSubpath()
context.saveGState()
context.setShadow(offset: .zero, blur: 46, color: NSColor.white.withAlphaComponent(0.5).cgColor)
context.addPath(bolt)
context.setFillColor(NSColor(calibratedRed: 0.82, green: 0.84, blue: 0.86, alpha: 1).cgColor)
context.fillPath()
context.restoreGState()

let portColors: [NSColor] = [
    NSColor(calibratedWhite: 0.88, alpha: 1),
    NSColor(calibratedWhite: 0.70, alpha: 1),
    NSColor(calibratedWhite: 0.52, alpha: 1)
]
for (index, color) in portColors.enumerated() {
    let x = CGFloat(390 + index * 122)
    let rect = CGRect(x: x, y: 111, width: 62, height: 18)
    let path = CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil)
    context.setFillColor(color.withAlphaComponent(0.9).cgColor)
    context.addPath(path)
    context.fillPath()
}

context.restoreGState()
context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
context.setLineWidth(3)
context.addPath(tile)
context.strokePath()
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to encode icon") }
try png.write(to: URL(fileURLWithPath: outputPath))
