// Turns icon/AppIcon-source.png (a rendered tile on a plain background) into a macOS .iconset:
// finds the tile, crops it, masks it to Apple's rounded-square shape on the 1024 grid
// (824px body, 100px margins) and adds the standard soft drop shadow.
// Usage: swift tools/make_icon.swift icon/AppIcon-source.png build/AppIcon.iconset
import AppKit
let src = CommandLine.arguments[1], out = CommandLine.arguments[2]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: src)))!
let cg = rep.cgImage!
func lum(_ x: Int, _ y: Int) -> CGFloat {
    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return (c.redComponent + c.greenComponent + c.blueComponent) / 3
}
// Tile edges: first pixels on the centre row/column that differ from the background colour.
let w = rep.pixelsWide, h = rep.pixelsHigh, bg = lum(2, 2)
func edge(_ range: [Int], _ at: (Int) -> CGFloat) -> Int { range.first { abs(at($0) - bg) > 0.05 }! }
let left = edge(Array(0..<w)) { lum($0, h / 2) }, right = edge(Array((0..<w).reversed())) { lum($0, h / 2) }
let top = edge(Array(0..<h)) { lum(w / 2, $0) }
let inset = 6, side = right - left - 2 * inset   // drop the anti-aliased rim of the original tile
let tile = cg.cropping(to: CGRect(x: left + inset, y: top + inset, width: side, height: side))!

// Apple's icon shape is a superellipse rather than a circular-arc rounded rect.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(), n = 5.0, steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi, c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = r.midY + r.height / 2 * CGFloat(copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath(); return p
}
func draw(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), shape = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s, color: NSColor(white: 0, alpha: 0.3).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.clip()
    ctx.draw(tile, in: body)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}
for (n, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(n).png"))
}
