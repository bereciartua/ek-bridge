// Draws the app icon: the sun's path across a day. The part of the day already
// gone is a solid line, the rest is dotted, and the red sun is "now".
// Run make_icon.sh to regenerate Resources/AppIcon.icns.
//
// Usage: make_icon <output.png> <pixels>
// Each size is drawn at its own pixel size instead of scaled down from 1024.
// At 32 px and below a simpler drawing is used: three big dots, no hour marks
// and thicker lines, because the full drawing blurs into a smudge there.
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 3, let pixels = Int(arguments[2]), pixels > 0 else {
    FileHandle.standardError.write("usage: make_icon <output.png> <pixels>\n".data(using: .utf8)!)
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])
let small = pixels <= 32

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let ink = color(0x1B2A4A)
let sunRed = color(0xFF5B4D)
let sunRing = color(0xFFEFE0)

// The drawing, in points on the 1024 canvas, measured from the top.
struct Drawing {
    var horizonY: CGFloat, radius: CGFloat = 300, sunAngle: CGFloat = 128
    var sunRadius: CGFloat, ringWidth: CGFloat, pathWidth: CGFloat
    var dotRadius: CGFloat, dotStep: CGFloat, firstDot: CGFloat
    var horizonWidth: CGFloat, horizonLeft: CGFloat, horizonRight: CGFloat
    var hourMarks: Int
}
let drawing = small
    ? Drawing(horizonY: 660, sunRadius: 128, ringWidth: 18, pathWidth: 66, dotRadius: 31, dotStep: 34,
              firstDot: 20, horizonWidth: 74, horizonLeft: 150, horizonRight: 874, hourMarks: 0)
    : Drawing(horizonY: 650, sunRadius: 100, ringWidth: 14, pathWidth: 46, dotRadius: 18, dotStep: 13,
              firstDot: 0, horizonWidth: 54, horizonLeft: 166, horizonRight: 858, hourMarks: 5)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setAllowsAntialiasing(true)
context.interpolationQuality = .high
let scale = CGFloat(pixels) / 1024
context.scaleBy(x: scale, y: scale)

// Core Graphics measures y from the bottom; the drawing measures it from the top.
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: 1024 - y) }
func onPath(_ degrees: CGFloat) -> CGPoint {
    let angle = degrees * .pi / 180
    return point(512 + drawing.radius * cos(angle), drawing.horizonY - drawing.radius * sin(angle))
}
func fillCircle(_ center: CGPoint, _ radius: CGFloat) {
    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

// macOS icon grid: an 824 pt rounded square centered on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the tile. Shadow sizes are in pixels, not points.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: color(0x000000, 0.28))
context.addPath(shape)
context.setFillColor(color(0xFFF3E2))
context.fillPath()
context.restoreGState()

// Dawn sky: cream at the top to peach at the bottom.
context.saveGState()
context.addPath(shape)
context.clip()
let dawn = CGGradient(colorsSpace: space, colors: [color(0xFFF3E2), color(0xFFD2B0)] as CFArray, locations: nil)!
context.drawLinearGradient(dawn, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

context.setLineCap(.round)
context.setStrokeColor(ink)
context.setFillColor(ink)

// The rest of the day: evenly spaced dots from the horizon up to the sun,
// stopping short of it.
let clearance = (drawing.sunRadius + drawing.dotRadius + 26) / drawing.radius * 180 / .pi
for degrees in stride(from: drawing.firstDot, to: drawing.sunAngle - clearance, by: drawing.dotStep) {
    fillCircle(onPath(degrees), drawing.dotRadius)
}

// The part of the day already gone: a solid arc from sunrise to the sun.
context.setLineWidth(drawing.pathWidth)
context.addArc(center: point(512, drawing.horizonY), radius: drawing.radius, startAngle: .pi,
               endAngle: drawing.sunAngle * .pi / 180, clockwise: true)
context.strokePath()

// The horizon.
context.setLineWidth(drawing.horizonWidth)
context.move(to: point(drawing.horizonLeft, drawing.horizonY))
context.addLine(to: point(drawing.horizonRight, drawing.horizonY))
context.strokePath()

// Hour marks under the horizon.
context.setStrokeColor(color(0x1B2A4A, 0.45))
context.setLineWidth(26)
for mark in 0..<drawing.hourMarks {
    let x = 262 + CGFloat(mark) * 125
    context.move(to: point(x, drawing.horizonY + 74))
    context.addLine(to: point(x, drawing.horizonY + 122))
}
context.strokePath()

// The sun, with a thin cream ring that keeps it apart from the line.
let sun = onPath(drawing.sunAngle)
context.setFillColor(sunRing)
fillCircle(sun, drawing.sunRadius + drawing.ringWidth)
context.setFillColor(sunRed)
fillCircle(sun, drawing.sunRadius)
context.restoreGState()

// A subtle inner edge so the tile reads on white backgrounds.
context.addPath(shape)
context.setStrokeColor(color(0x000000, 0.07))
context.setLineWidth(4)
context.strokePath()

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
