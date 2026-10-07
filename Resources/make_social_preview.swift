// Draws the repository's social preview (the image link previews show for
// github.com/bereciartua/ek-bridge): the app icon, name and tagline beside the
// Overview screenshot, at GitHub's recommended 1280 x 640. Run
// make_social_preview.sh to regenerate docs/images/social-preview.png, then
// upload it in the repository's Settings ▸ General ▸ Social preview.
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: make_social_preview ICON SCREENSHOT OUTPUT\n".utf8))
    exit(2)
}
let width: CGFloat = 1280
let height: CGFloat = 640

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func image(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("make_social_preview: can't read \(path)\n".utf8))
        exit(1)
    }
    return image
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high

// Background: a light wash from white to the icon's dawn cream, faintly.
let background = CGGradient(colorsSpace: space,
                            colors: [color(0xFFFFFF), color(0xFFF1E3)] as CFArray, locations: nil)!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0),
                           options: [])

// The Overview window on the right, as it looks on screen (it has its own
// transparent rounded corners), with a window shadow.
let screenshot = image(arguments[2])
let shotWidth: CGFloat = 660
let shotHeight = shotWidth * CGFloat(screenshot.height) / CGFloat(screenshot.width)
let shot = CGRect(x: width - shotWidth - 56, y: (height - shotHeight) / 2, width: shotWidth, height: shotHeight)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: color(0x0A2A5C, 0.22))
context.draw(screenshot, in: shot)
context.restoreGState()

// The icon, name and tagline on the left.
let left: CGFloat = 72
let iconSize: CGFloat = 168
// The icon's artwork sits on Apple's grid inside its 1024 canvas (100 pt margins).
let iconInset = iconSize * 100 / 1024
context.draw(image(arguments[1]),
             in: CGRect(x: left - iconInset, y: height - 92 - iconSize + iconInset, width: iconSize, height: iconSize))

NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, hex: Int, top: CGFloat, lineHeight: CGFloat? = nil) {
    let paragraph = NSMutableParagraphStyle()
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    let string = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color(hex))!,
        .paragraphStyle: paragraph,
    ])
    let box = CGRect(x: left, y: 0, width: shot.minX - left - 40, height: height - top)
    string.draw(with: box, options: [.usesLineFragmentOrigin])
}
draw("EK Bridge", size: 72, weight: .bold, hex: 0x111827, top: 290)
draw("Scoped Calendar and Reminders access for AI agents on your Mac", size: 30, weight: .regular,
     hex: 0x374151, top: 384, lineHeight: 40)
draw("MCP server · per-client grants · approvals", size: 22, weight: .medium, hex: 0x0A5AD4, top: 520)
draw("Open source · Apache-2.0", size: 22, weight: .regular, hex: 0x6B7280, top: 556)
NSGraphicsContext.current = nil

let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[3]) as CFURL,
                                                  "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
