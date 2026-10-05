// Draws the app icon: a calendar page with a bridge arc. Run make_icon.sh to
// regenerate Resources/AppIcon.icns. Placeholder-quality art made in code, so
// it can be replaced by a commissioned icon without changing the build.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
               locations: nil)!
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

// macOS icon grid: an 824 pt rounded square centered on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the page.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
context.addPath(shape)
context.setFillColor(color(0xFFFFFF))
context.fillPath()
context.restoreGState()

// Page: white to a soft grey.
context.saveGState()
context.addPath(shape)
context.clip()
context.drawLinearGradient(gradient([color(0xFFFFFF), color(0xEEF0F4)]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY),
                           options: [])

// Red header band, like a calendar page.
let bandHeight: CGFloat = 238
let band = CGRect(x: body.minX, y: body.maxY - bandHeight, width: body.width, height: bandHeight)
context.saveGState()
context.clip(to: band)
context.drawLinearGradient(gradient([color(0xFF6B5E), color(0xE8382C)]),
                           start: CGPoint(x: 0, y: band.maxY), end: CGPoint(x: 0, y: band.minY),
                           options: [])
context.restoreGState()
// A hairline under the band.
context.setFillColor(color(0x000000, 0.10))
context.fill(CGRect(x: body.minX, y: band.minY - 3, width: body.width, height: 3))

// Binding holes on the band.
for x in [body.minX + 230, body.maxX - 230] {
    let hole = CGRect(x: x - 26, y: band.minY + bandHeight * 0.5 - 26, width: 52, height: 52)
    context.setFillColor(color(0x9E1B12, 0.35))
    context.fillEllipse(in: hole.offsetBy(dx: 0, dy: -3))
    context.setFillColor(color(0xFFFFFF, 0.95))
    context.fillEllipse(in: hole)
}

// The bridge: a deck, an arch and hangers, in blue.
let blueTop = color(0x2F8BFF)
let blueBottom = color(0x0A5AD4)
let deckY: CGFloat = 300
let left: CGFloat = 220
let right: CGFloat = 804
let archTop: CGFloat = 590
let bridge = CGMutablePath()
// Arch: a quadratic curve from pier to pier.
bridge.move(to: CGPoint(x: left, y: deckY))
bridge.addQuadCurve(to: CGPoint(x: right, y: deckY),
                    control: CGPoint(x: (left + right) / 2, y: archTop + (archTop - deckY)))
let archStroke = bridge.copy(strokingWithWidth: 58, lineCap: .round, lineJoin: .round, miterLimit: 10)

var shapes = [CGPath]()
shapes.append(archStroke)
// Deck.
shapes.append(CGPath(roundedRect: CGRect(x: left - 70, y: deckY - 34, width: right - left + 140, height: 52),
                      cornerWidth: 26, cornerHeight: 26, transform: nil))
// Hangers between the arch and the deck.
func archY(_ x: CGFloat) -> CGFloat {
    let t = (x - left) / (right - left)
    let control = archTop + (archTop - deckY)
    return (1 - t) * (1 - t) * deckY + 2 * (1 - t) * t * control + t * t * deckY
}
for x in stride(from: left + 110, through: right - 110, by: 91) {
    let top = archY(x) - 18
    shapes.append(CGPath(roundedRect: CGRect(x: x - 11, y: deckY, width: 22, height: max(0, top - deckY)),
                          cornerWidth: 11, cornerHeight: 11, transform: nil))
}
// Piers into the water line.
for x in [left, right] {
    shapes.append(CGPath(roundedRect: CGRect(x: x - 26, y: deckY - 120, width: 52, height: 120),
                          cornerWidth: 12, cornerHeight: 12, transform: nil))
}
// Each part is filled on its own, so overlaps never cancel out, and the
// shadow applies to the bridge as a whole.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: color(0x0A3A8C, 0.25))
context.beginTransparencyLayer(auxiliaryInfo: nil)
for part in shapes {
    context.saveGState()
    context.addPath(part)
    context.clip()
    context.drawLinearGradient(gradient([blueTop, blueBottom]),
                               start: CGPoint(x: 0, y: archTop + 40), end: CGPoint(x: 0, y: deckY - 120),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}
context.endTransparencyLayer()
context.restoreGState()

// Water line under the bridge.
context.setStrokeColor(color(0x0A5AD4, 0.22))
context.setLineWidth(14)
context.setLineCap(.round)
context.move(to: CGPoint(x: left - 60, y: deckY - 150))
context.addLine(to: CGPoint(x: right + 60, y: deckY - 150))
context.strokePath()
context.restoreGState()

// A subtle inner edge so the page reads on white backgrounds.
context.addPath(shape)
context.setStrokeColor(color(0x000000, 0.08))
context.setLineWidth(2)
context.strokePath()

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
