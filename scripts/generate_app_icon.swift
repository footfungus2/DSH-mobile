import AppKit
import CoreGraphics

let size = CGSize(width: 1024, height: 1024)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let context = CGContext(
    data: nil,
    width: Int(size.width),
    height: Int(size.height),
    bitsPerComponent: 8,
    bytesPerRow: Int(size.width) * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fatalError("Failed to create CGContext")
}

let rect = CGRect(origin: .zero, size: size)

// 1. Deep Oceanic Abyssal Slate Background Gradient
let bgColors = [
    NSColor(red: 16/255, green: 22/255, blue: 32/255, alpha: 1.0).cgColor, // Top: deep oceanic twilight
    NSColor(red: 8/255, green: 11/255, blue: 17/255, alpha: 1.0).cgColor   // Bottom: abyss
]
let bgLocations: [CGFloat] = [0.0, 1.0]
let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors as CFArray, locations: bgLocations)!
context.drawLinearGradient(bgGradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

// 2. Subtle Ambient Radial Depth Light behind the fluke
let radialColors = [
    NSColor(red: 30/255, green: 102/255, blue: 245/255, alpha: 0.18).cgColor,
    NSColor(red: 16/255, green: 40/255, blue: 100/255, alpha: 0.05).cgColor,
    NSColor(red: 0, green: 0, blue: 0, alpha: 0.0).cgColor
]
let radialLocations: [CGFloat] = [0.0, 0.45, 1.0]
let radialGradient = CGGradient(colorsSpace: colorSpace, colors: radialColors as CFArray, locations: radialLocations)!
context.drawRadialGradient(radialGradient, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 480, options: [])

// 3. Precision Concentric Sonar Waves
context.saveGState()
context.setLineCap(.round)
let sonarCenter = CGPoint(x: 512, y: 460)
let rings: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [
    (180, 2.5, 0.20),
    (270, 2.0, 0.13),
    (370, 1.5, 0.08),
    (470, 1.0, 0.04)
]
for ring in rings {
    context.setStrokeColor(NSColor(red: 90/255, green: 160/255, blue: 255/255, alpha: ring.alpha).cgColor)
    context.setLineWidth(ring.width)
    context.addEllipse(in: CGRect(x: sonarCenter.x - ring.radius, y: sonarCenter.y - ring.radius, width: ring.radius * 2, height: ring.radius * 2))
    context.strokePath()
}
context.restoreGState()

// 4. Hero Glyph: The Whale's Fluke / Abyssal Fin
// In CoreGraphics, (0,0) is bottom-left, (1024,1024) is top-right.
let flukePath = CGMutablePath()

// Starting from base of peduncle (stalk)
let peduncleLeft = CGPoint(x: 480, y: 350)
let peduncleRight = CGPoint(x: 544, y: 350)
let tipLeft = CGPoint(x: 180, y: 640)
let tipRight = CGPoint(x: 844, y: 640)
let notch = CGPoint(x: 512, y: 590)

flukePath.move(to: peduncleLeft)

// Leading Edge: Up and left to left tip
flukePath.addCurve(to: CGPoint(x: 240, y: 540), control1: CGPoint(x: 460, y: 440), control2: CGPoint(x: 340, y: 490))
flukePath.addCurve(to: tipLeft, control1: CGPoint(x: 190, y: 565), control2: CGPoint(x: 175, y: 610))

// Trailing Edge: Left tip inward to median notch
flukePath.addCurve(to: CGPoint(x: 350, y: 665), control1: CGPoint(x: 215, y: 655), control2: CGPoint(x: 280, y: 668))
flukePath.addCurve(to: notch, control1: CGPoint(x: 430, y: 660), control2: CGPoint(x: 485, y: 610))

// Trailing Edge: Median notch outward to right tip
flukePath.addCurve(to: CGPoint(x: 674, y: 665), control1: CGPoint(x: 539, y: 610), control2: CGPoint(x: 594, y: 660))
flukePath.addCurve(to: tipRight, control1: CGPoint(x: 744, y: 668), control2: CGPoint(x: 809, y: 655))

// Leading Edge: Right tip down and in to peduncle right
flukePath.addCurve(to: CGPoint(x: 784, y: 540), control1: CGPoint(x: 849, y: 610), control2: CGPoint(x: 834, y: 565))
flukePath.addCurve(to: peduncleRight, control1: CGPoint(x: 684, y: 490), control2: CGPoint(x: 564, y: 440))

// Base closure with slight curve
flukePath.addCurve(to: peduncleLeft, control1: CGPoint(x: 528, y: 335), control2: CGPoint(x: 496, y: 335))
flukePath.closeSubpath()

// Drop Shadow under the fluke
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -22), blur: 34, color: NSColor(red: 0, green: 0, blue: 0, alpha: 0.65).cgColor)
context.addPath(flukePath)
context.setFillColor(NSColor(red: 20/255, green: 70/255, blue: 180/255, alpha: 1.0).cgColor)
context.fillPath()
context.restoreGState()

// Clip to fluke path and draw Electric Azure gradient
context.saveGState()
context.addPath(flukePath)
context.clip()

let flukeColors = [
    NSColor(red: 90/255, green: 175/255, blue: 255/255, alpha: 1.0).cgColor, // Top tips highlight: light electric cyan
    NSColor(red: 30/255, green: 102/255, blue: 245/255, alpha: 1.0).cgColor, // Mid fluke: DeepSeek signature electric azure
    NSColor(red: 12/255, green: 55/255, blue: 170/255, alpha: 1.0).cgColor,  // Lower fluke: ocean cobalt
    NSColor(red: 6/255, green: 28/255, blue: 95/255, alpha: 0.95).cgColor   // Stalk base: abyssal indigo
]
let flukeLocations: [CGFloat] = [0.0, 0.40, 0.75, 1.0]
let flukeGradient = CGGradient(colorsSpace: colorSpace, colors: flukeColors as CFArray, locations: flukeLocations)!
context.drawLinearGradient(flukeGradient, start: CGPoint(x: 512, y: 680), end: CGPoint(x: 512, y: 340), options: [])

// Specular trailing rim light (top edge glow)
context.setStrokeColor(NSColor(red: 220/255, green: 240/255, blue: 255/255, alpha: 0.55).cgColor)
context.setLineWidth(3.0)
context.addPath(flukePath)
context.strokePath()

context.restoreGState()

// 5. Intelligent AI Spark Beacon (above the notch)
let sparkCenter = CGPoint(x: 512, y: 725)

// Beacon soft glow
let beaconColors = [
    NSColor(red: 165/255, green: 215/255, blue: 255/255, alpha: 0.45).cgColor,
    NSColor(red: 30/255, green: 102/255, blue: 245/255, alpha: 0.0).cgColor
]
let beaconGradient = CGGradient(colorsSpace: colorSpace, colors: beaconColors as CFArray, locations: [0.0, 1.0])!
context.drawRadialGradient(beaconGradient, startCenter: sparkCenter, startRadius: 0, endCenter: sparkCenter, endRadius: 40, options: [])

// 4-Point Spark Glyph
let sparkPath = CGMutablePath()
let rOuter: CGFloat = 18.0
let rInner: CGFloat = 4.5

sparkPath.move(to: CGPoint(x: sparkCenter.x, y: sparkCenter.y + rOuter))
sparkPath.addQuadCurve(to: CGPoint(x: sparkCenter.x + rOuter, y: sparkCenter.y), control: CGPoint(x: sparkCenter.x + rInner, y: sparkCenter.y + rInner))
sparkPath.addQuadCurve(to: CGPoint(x: sparkCenter.x, y: sparkCenter.y - rOuter), control: CGPoint(x: sparkCenter.x + rInner, y: sparkCenter.y - rInner))
sparkPath.addQuadCurve(to: CGPoint(x: sparkCenter.x - rOuter, y: sparkCenter.y), control: CGPoint(x: sparkCenter.x - rInner, y: sparkCenter.y - rInner))
sparkPath.addQuadCurve(to: CGPoint(x: sparkCenter.x, y: sparkCenter.y + rOuter), control: CGPoint(x: sparkCenter.x - rInner, y: sparkCenter.y + rInner))
sparkPath.closeSubpath()

context.saveGState()
context.addPath(sparkPath)
context.setFillColor(NSColor(red: 240/255, green: 248/255, blue: 255/255, alpha: 0.95).cgColor)
context.setShadow(offset: .zero, blur: 10, color: NSColor(red: 100/255, green: 180/255, blue: 255/255, alpha: 0.8).cgColor)
context.fillPath()
context.restoreGState()

guard let cgImage = context.makeImage() else {
    fatalError("Failed to render CGImage")
}

let rep = NSBitmapImageRep(cgImage: cgImage)
rep.size = size
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode PNG")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Successfully generated App Icon at: \(outputPath)")
