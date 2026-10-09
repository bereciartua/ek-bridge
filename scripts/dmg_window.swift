// The window people see when they open EKBridge.dmg: a cream background with
// the icon's dotted day arc leading from the app to the Applications folder,
// and the Finder settings (.DS_Store) that size the window, hide its toolbar
// and sidebar, place both icons over the art and point at the background.
// scripts/make_dmg.sh compiles it and runs both commands:
//
//   dmg_window background OUT.png SCALE   draws the art at 1x or 2x
//   dmg_window layout VOLUME BACKGROUND APP   writes VOLUME/.DS_Store
//
// BACKGROUND is the image's path inside the mounted volume and APP the app's
// file name. The .DS_Store is written here rather than by scripting Finder,
// which needs a logged-in session and Automation access (CI has neither), or by
// a Python package. Its format (a buddy allocator holding a B-tree of records)
// and the alias format are the ones Finder writes; the layout needs only one
// B-tree node. Finder resolves the background through the bookmark (pBBk) and
// falls back to the alias inside the view settings (icvp).
import AppKit
import CoreGraphics
import Foundation

// One geometry for the art and the layout, in points. Finder draws the
// background from the top left of the window's content, which on macOS 26 and
// later sits between the title bar and a status bar Finder shows even when told
// not to. The window is sized so visibleHeight points show; the art stays in
// them, and the cream continues below for a Finder that shows more.
let windowSize = CGSize(width: 660, height: 440)
let visibleHeight: CGFloat = 400
let iconSize: CGFloat = 128
// Icon centers, measured from the window's top left (Finder's coordinates).
let appCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 490, y: 190)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dmg_window: \(message)\n".utf8))
    exit(1)
}

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// MARK: - Background

func drawBackground(to path: String, scale: CGFloat) {
    let width = Int(windowSize.width * scale), height = Int(windowSize.height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("can't create a \(width) x \(height) bitmap")
    }
    context.scaleBy(x: scale, y: scale)
    // From here on y grows upwards, so a Finder point (x, y) is (x, H - y).
    let h = windowSize.height
    func flipped(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }

    // The icon's dawn cream, lighter at the top.
    let wash = CGGradient(colorsSpace: space, colors: [color(0xFFF8EF), color(0xFFE9D4)] as CFArray,
                          locations: nil)!
    context.drawLinearGradient(wash, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

    // A soft rounded tile behind each icon, like a drop target, ending above
    // the icon's label.
    for center in [appCenter, applicationsCenter] {
        let c = flipped(center)
        let tile = CGRect(x: c.x - 78, y: c.y - 72, width: 156, height: 152)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 14, color: color(0xB86A2E, 0.10))
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 40, cornerHeight: 40, transform: nil))
        context.setFillColor(color(0xFFFFFF, 0.55))
        context.fillPath()
        context.restoreGState()
    }

    // The day arc: navy dots rising from the app and setting on Applications,
    // ending in an arrowhead, as on the app icon.
    let navy = color(0x1D2A4C)
    let start = flipped(CGPoint(x: appCenter.x + 36, y: appCenter.y - 98))
    let end = flipped(CGPoint(x: applicationsCenter.x - 36, y: applicationsCenter.y - 98))
    let control = CGPoint(x: (start.x + end.x) / 2, y: start.y + 84)
    func arc(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }
    // Even spacing along the curve, not in t.
    var samples: [(t: CGFloat, length: CGFloat)] = [(0, 0)]
    var previous = arc(0)
    for i in 1...400 {
        let t = CGFloat(i) / 400, p = arc(t)
        samples.append((t, samples[samples.count - 1].length + hypot(p.x - previous.x, p.y - previous.y)))
        previous = p
    }
    let total = samples[samples.count - 1].length
    func point(atLength length: CGFloat) -> CGPoint {
        let i = samples.firstIndex { $0.length >= length } ?? samples.count - 1
        return arc(samples[i].t)
    }
    // An odd number of dots, so the middle one can be the sun.
    let dots = 13
    let arrowRoom: CGFloat = 22
    let sun = point(atLength: (total - arrowRoom) / 2)
    context.setFillColor(navy)
    for i in 0..<dots where i != dots / 2 {
        let p = point(atLength: (total - arrowRoom) * CGFloat(i) / CGFloat(dots - 1))
        let radius: CGFloat = 3.4
        context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }
    // The arrowhead, pointing along the curve's end.
    let tip = end, back = arc(0.9)
    let angle = atan2(tip.y - back.y, tip.x - back.x)
    let head = CGMutablePath()
    let length: CGFloat = 12, spread: CGFloat = 0.55
    head.move(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
    head.addLine(to: tip)
    head.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
    context.addPath(head)
    context.setStrokeColor(navy)
    context.setLineWidth(3.4)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    // The sun: the icon's coral dot at the top of the arc.
    context.setFillColor(color(0xFFF4E8))
    context.fillEllipse(in: CGRect(x: sun.x - 13, y: sun.y - 13, width: 26, height: 26))
    context.setFillColor(color(0xFF5A4A))
    context.fillEllipse(in: CGRect(x: sun.x - 10, y: sun.y - 10, width: 20, height: 20))

    // The instruction, under the icons' labels.
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current = graphics
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let base = NSFont.systemFont(ofSize: 15, weight: .medium)
    let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 15) } ?? base
    let text = NSAttributedString(string: "Drag to Applications to install", attributes: [
        .font: rounded, .foregroundColor: NSColor(cgColor: color(0x1D2A4C, 0.62))!, .paragraphStyle: paragraph,
    ])
    text.draw(in: CGRect(x: 0, y: h - 342, width: windowSize.width, height: 24))
    NSGraphicsContext.current = nil

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            "public.png" as CFString, 1, nil) else {
        fail("can't write \(path)")
    }
    // 72 dpi per point, so tiffutil -cathidpicheck pairs the 1x and 2x images.
    let dpi = 72 * scale
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi,
                                                    kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fail("can't write \(path)") }
}

// MARK: - Alias

func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

func pascal(_ string: String, size: Int) -> Data {
    var bytes = Array(string.replacingOccurrences(of: ":", with: "/").utf8.prefix(size - 1))
    bytes.insert(UInt8(bytes.count), at: 0)
    return Data(bytes + Array(repeating: 0, count: size - bytes.count))
}

/// A classic alias record (version 2) for a file in a volume's root folder, as
/// Finder stores for a window's background picture.
func alias(for url: URL, volume: URL) -> Data {
    let fileValues = try? url.resourceValues(forKeys: [.creationDateKey])
    let volumeValues = try? volume.resourceValues(forKeys: [.volumeNameKey, .volumeCreationDateKey])
    guard let created = fileValues?.creationDate, let volumeName = volumeValues?.volumeName,
          let volumeCreated = volumeValues?.volumeCreationDate else {
        fail("can't read the dates of \(url.path)")
    }
    var fileInfo = stat(), folderInfo = stat()
    guard stat(url.path, &fileInfo) == 0, stat(volume.path, &folderInfo) == 0 else {
        fail("can't stat \(url.path)")
    }
    // Seconds since 1904, Mac OS's epoch.
    let macEpoch = Date(timeIntervalSince1970: -2_082_844_800)
    let volumeSeconds = volumeCreated.timeIntervalSince(macEpoch)
    let fileSeconds = created.timeIntervalSince(macEpoch)
    let name = url.lastPathComponent

    var record = Data("\0\0\0\0".utf8) + bigEndian(UInt16(0)) + bigEndian(UInt16(2))
    record += bigEndian(UInt16(0)) // a file
    record += pascal(volumeName, size: 28)
    record += bigEndian(UInt32(volumeSeconds))
    record += Data("H+".utf8) + bigEndian(UInt16(0)) // HFS+, fixed disk
    record += bigEndian(UInt32(truncatingIfNeeded: folderInfo.st_ino))
    record += pascal(name, size: 64)
    record += bigEndian(UInt32(truncatingIfNeeded: fileInfo.st_ino))
    record += bigEndian(UInt32(fileSeconds))
    record += Data(count: 8) // creator and type codes
    record += bigEndian(Int16(-1)) + bigEndian(Int16(-1)) // levels from and to
    record += Data(count: 16) // volume attributes, file system ID, reserved

    func tag(_ tag: Int16, _ value: Data) {
        record += bigEndian(tag) + bigEndian(UInt16(value.count)) + value
        if value.count % 2 == 1 { record += Data(count: 1) }
    }
    func utf16(_ string: String) -> Data {
        let units = string.replacingOccurrences(of: ":", with: "/").utf16
        return bigEndian(UInt16(units.count)) + units.reduce(Data()) { $0 + bigEndian($1) }
    }
    tag(0, Data(volumeName.replacingOccurrences(of: ":", with: "/").utf8)) // folder name
    tag(16, bigEndian(UInt64(volumeSeconds * 65536))) // volume creation date
    tag(17, bigEndian(UInt64(fileSeconds * 65536))) // creation date
    tag(2, Data("\(volumeName):\(name)".utf8)) // Carbon path
    tag(14, utf16(name))
    tag(15, utf16(volumeName))
    tag(18, Data("/\(name)".utf8)) // path in the volume
    tag(19, Data(volume.path.utf8)) // mount point
    record += bigEndian(Int16(-1)) + bigEndian(UInt16(0))
    record.replaceSubrange(4..<6, with: bigEndian(UInt16(record.count)))
    return record
}

// MARK: - .DS_Store

enum Value {
    case blob(Data), long(UInt32), type(String), bool(Bool)
}

/// One B-tree record: a file name, a four-character property code and a value.
func encode(_ name: String, _ code: String, _ value: Value) -> Data {
    let units = Array(name.utf16)
    var data = bigEndian(UInt32(units.count)) + units.reduce(Data()) { $0 + bigEndian($1) }
    data += Data(code.utf8)
    switch value {
    case .blob(let blob): data += Data("blob".utf8) + bigEndian(UInt32(blob.count)) + blob
    case .long(let long): data += Data("long".utf8) + bigEndian(long)
    case .type(let type): data += Data("type".utf8) + Data(type.utf8)
    case .bool(let bool): data += Data("bool".utf8) + Data([bool ? 1 : 0])
    }
    return data
}

func plist(_ object: [String: Any]) -> Data {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) else {
        fail("can't encode a property list")
    }
    return data
}

/// The whole file. Blocks live at power-of-two addresses in a 2 GB address
/// space (counted from byte 4): the header at 0 (32 bytes), the B-tree's
/// header at 32 (32), the allocator's own block at 2048 (2048), and the one
/// B-tree node at 4096 (4096). Every other power of two is on the free lists.
func dsStore(_ records: [(name: String, code: String, value: Value)]) -> Data {
    // Finder looks records up in file name order (case-insensitive), then code.
    let sorted = records.sorted {
        let a = $0.name.lowercased(), b = $1.name.lowercased()
        return a != b ? a.utf16.lexicographicallyPrecedes(b.utf16) : $0.code < $1.code
    }
    var node = bigEndian(UInt32(0)) + bigEndian(UInt32(sorted.count)) // a leaf
    for record in sorted { node += encode(record.name, record.code, record.value) }
    guard node.count <= 4096 else { fail("the .DS_Store records don't fit in one node") }
    node += Data(count: 4096 - node.count)

    // B-tree header: root node (block 2), levels, records, nodes, page size.
    var tree = [2, 0, UInt32(sorted.count), 1, 4096].reduce(Data()) { $0 + bigEndian($1) }
    tree += Data(count: 32 - tree.count)

    // The allocator's block: the block addresses (offset | log2 size), padded
    // to 256 entries, the table of contents, and 32 free lists by size.
    var root = bigEndian(UInt32(3)) + bigEndian(UInt32(0))
    for address in [2048 | 11, 32 | 5, 4096 | 12] as [UInt32] { root += bigEndian(address) }
    root += Data(count: 253 * 4)
    root += bigEndian(UInt32(1)) + Data([4]) + Data("DSDB".utf8) + bigEndian(UInt32(1))
    for width in 0..<32 {
        if (6...10).contains(width) || (13...30).contains(width) {
            root += bigEndian(UInt32(1)) + bigEndian(UInt32(1) << width)
        } else {
            root += bigEndian(UInt32(0))
        }
    }

    var file = Data(count: 4 + 8192)
    var header = bigEndian(UInt32(1)) + Data("Bud1".utf8)
    header += bigEndian(UInt32(2048)) + bigEndian(UInt32(root.count)) + bigEndian(UInt32(2048))
    header += Data([0, 0, 0x10, 0x0c, 0, 0, 0, 0x87, 0, 0, 0x20, 0x0b, 0, 0, 0, 0])
    file.replaceSubrange(0..<header.count, with: header)
    file.replaceSubrange((4 + 32)..<(4 + 32 + tree.count), with: tree)
    file.replaceSubrange((4 + 2048)..<(4 + 2048 + root.count), with: root)
    file.replaceSubrange((4 + 4096)..<(4 + 8192), with: node)
    return file
}

func writeLayout(volumePath: String, backgroundPath: String, appName: String) {
    let volume = URL(fileURLWithPath: volumePath, isDirectory: true)
    let background = URL(fileURLWithPath: backgroundPath)
    guard background.deletingLastPathComponent().standardizedFileURL.path == volume.standardizedFileURL.path else {
        fail("the background must be in the volume's root folder")
    }
    guard let bookmark = try? background.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                      relativeTo: nil) else {
        fail("can't make a bookmark to \(backgroundPath)")
    }
    // Where the window opens on screen, and its size with the title and status bars.
    let bounds = "{{200, 120}, {\(Int(windowSize.width)), \(Int(visibleHeight + 60))}}"
    let browser: [String: Any] = [
        "ContainerShowSidebar": false, "ShowPathbar": false, "ShowSidebar": false, "ShowStatusBar": false,
        "ShowTabView": false, "ShowToolbar": false, "SidebarWidth": 0, "WindowBounds": bounds,
    ]
    let iconView: [String: Any] = [
        "arrangeBy": "none", "backgroundType": 2, "backgroundImageAlias": alias(for: background, volume: volume),
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "iconSize": Double(iconSize),
        "labelOnBottom": true, "showIconPreview": true, "showItemInfo": false, "textSize": 13.0,
        "viewOptionsVersion": 1,
    ]
    func location(_ p: CGPoint) -> Value {
        .blob(bigEndian(UInt32(p.x)) + bigEndian(UInt32(p.y)) + Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0]))
    }
    let store = dsStore([
        (".", "bwsp", .blob(plist(browser))),
        (".", "icvp", .blob(plist(iconView))),
        (".", "pBBk", .blob(bookmark)),
        (".", "vSrn", .long(1)),
        (".", "vstl", .type("icnv")),
        (appName, "Iloc", location(appCenter)),
        ("Applications", "Iloc", location(applicationsCenter)),
    ])
    do {
        try store.write(to: volume.appendingPathComponent(".DS_Store"))
    } catch {
        fail("can't write the .DS_Store: \(error.localizedDescription)")
    }
}

let arguments = CommandLine.arguments
switch (arguments.count, arguments.count > 1 ? arguments[1] : "") {
case (4, "background"):
    guard let scale = Double(arguments[3]), scale >= 1 else { fail("SCALE must be 1 or 2") }
    drawBackground(to: arguments[2], scale: CGFloat(scale))
case (5, "layout"):
    writeLayout(volumePath: arguments[2], backgroundPath: arguments[3], appName: arguments[4])
default:
    FileHandle.standardError.write(Data("""
        usage: dmg_window background OUT.png SCALE
               dmg_window layout VOLUME BACKGROUND APP

        """.utf8))
    exit(2)
}
