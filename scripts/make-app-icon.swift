// Generates Resources/AppIcon.icns — the Suit app icon: a navy suit-jacket
// background with a white shirt collar and a striped red necktie.
//
// Usage (from the repo root):
//   swiftc -O scripts/make-app-icon.swift -o /tmp/make-app-icon && /tmp/make-app-icon
//
// Writes a 1024px master PNG, downscales the standard icon sizes with sips,
// and packs them into Resources/AppIcon.icns with iconutil.

import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
    for pt in pts.dropFirst() { p.line(to: NSPoint(x: pt.0, y: pt.1)) }
    p.close()
    return p
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon canvas: 824x824 rounded square centered in a 1024 canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185).addClip()

// Jacket: navy gradient, subtly lighter at the top.
NSGradient(starting: rgb(0x2F4262), ending: rgb(0x131B2A))!.draw(in: plate, angle: -90)

// Shirt collar: a white V narrowing from the top edge down to the tie knot.
rgb(0xEEF1F5).setFill()
poly([(422, 924), (512, 700), (602, 924)]).fill()

// Necktie. The knot overlaps the bottom of the collar V; the body flares out
// below it and ends in the classic point.
let knot = poly([(445, 762), (579, 762), (551, 645), (473, 645)])
let body = poly([(473, 645), (416, 330), (512, 222), (608, 330), (551, 645)])
NSGradient(starting: rgb(0xD9414D), ending: rgb(0x9E2631))!.draw(in: body, angle: -90)
NSGradient(starting: rgb(0xC53844), ending: rgb(0x8F202B))!.draw(in: knot, angle: -90)

// Diagonal stripes, clipped to the tie.
NSGraphicsContext.saveGraphicsState()
let tie = NSBezierPath()
tie.append(knot)
tie.append(body)
tie.addClip()
rgb(0xFFFFFF, 0.14).setFill()
var x: CGFloat = -500
while x < 1100 {
    poly([(x, 100), (x + 46, 100), (x + 546, 924), (x + 500, 924)]).fill()
    x += 150
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

// Write the master PNG, then pack the .icns.
let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "\(tool) \(args) failed")
}

for size in [16, 32, 128, 256, 512] {
    run("/usr/bin/sips", ["-z", "\(size)", "\(size)", master.path,
                          "--out", iconset.appendingPathComponent("icon_\(size)x\(size).png").path])
    if size < 512 {
        run("/usr/bin/sips", ["-z", "\(size * 2)", "\(size * 2)", master.path,
                              "--out", iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png").path])
    }
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path,
                          "-o", root.appendingPathComponent("Resources/AppIcon.icns").path])
print("wrote Resources/AppIcon.icns")
