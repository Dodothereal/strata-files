// Renders the app icon: a two-tone face in purple, a mirrored nod to Finder's.
//
//   swift scripts/make-icon.swift            # writes Resources/AppIcon.icns (+ build/icon-1024.png preview)
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

/// Apple's icon tile is close to a superellipse; n≈5 matches the system mask.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + rect.width / 2 * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + rect.height / 2 * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Tile on the standard 824pt grid, with the soft drop shadow macOS icons carry.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0xE8DDFB))
ctx.fillPath()
ctx.restoreGState()

/// Tile-local coordinates (origin top-left, y down, 0…824) to canvas coordinates.
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x, y: tile.maxY - y) }

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Light face on the left.
ctx.drawLinearGradient(gradient([rgb(0xFCF9FF), rgb(0xE6DAFA)]), start: p(0, 0), end: p(0, 824), options: [])

// Purple face on the right; its edge is the light face's profile, nose pointing into the purple side.
let profile = CGMutablePath()
profile.move(to: p(436, -20))
profile.addCurve(to: p(418, 432), control1: p(418, 140), control2: p(410, 320))
profile.addCurve(to: p(492, 530), control1: p(438, 468), control2: p(500, 504))
profile.addCurve(to: p(424, 568), control1: p(486, 556), control2: p(450, 562))
profile.addCurve(to: p(452, 850), control1: p(436, 660), control2: p(442, 760))
profile.addLine(to: p(860, 850))
profile.addLine(to: p(860, -20))
profile.closeSubpath()
ctx.saveGState()
ctx.addPath(profile)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xB98CFF), rgb(0x8B5CF6), rgb(0x6D28D9)], [0, 0.5, 1]),
                       start: p(0, 0), end: p(0, 824), options: [])
ctx.restoreGState()

// Eyes and smile.
let ink = rgb(0x22104A)
ctx.setFillColor(ink)
for x in [CGFloat(214), 586] {
    let eye = CGRect(x: tile.minX + x - 25, y: tile.maxY - 376, width: 50, height: 150)
    ctx.addPath(CGPath(roundedRect: eye, cornerWidth: 25, cornerHeight: 25, transform: nil))
    ctx.fillPath()
}
let smile = CGMutablePath()
smile.move(to: p(196, 622))
smile.addQuadCurve(to: p(616, 628), control: p(400, 752))
ctx.addPath(smile)
ctx.setStrokeColor(ink)
ctx.setLineWidth(28)
ctx.setLineCap(.round)
ctx.strokePath()

// Rim light along the top of the tile.
ctx.addPath(tilePath)
ctx.setLineWidth(4)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.5), rgb(0xFFFFFF, 0)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

let image = ctx.makeImage()!
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let buildDir = root.appending(path: "build")
let iconset = buildDir.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, size: Int, to url: URL) throws {
    let scaled = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: scaled.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try writePNG(image, size: 1024, to: buildDir.appending(path: "icon-1024.png"))
for base in [16, 32, 128, 256, 512] {
    try writePNG(image, size: base, to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try writePNG(image, size: base * 2, to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
