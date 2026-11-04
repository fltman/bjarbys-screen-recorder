// Ritar appikonen (1024 px) med CoreGraphics. Kör: swift scripts/make-icon.swift <ut.png>
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS-ikonens rutnät: 824 px fyrkant med rundade hörn, centrerad, lite skugga.
let inset = (size - 824) / 2
let tile = CGRect(x: inset, y: inset + 10, width: 824, height: 824)
let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

// Gradient som standardbakgrunden (#4F46E5 → #DB2777).
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0x4F/255, green: 0x46/255, blue: 0xE5/255, alpha: 1),
    CGColor(red: 0xDB/255, green: 0x27/255, blue: 0x77/255, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Ett fönster med rundade hörn.
let win = CGRect(x: tile.minX + 130, y: tile.minY + 200, width: 564, height: 420)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(CGPath(roundedRect: win, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.setFillColor(CGColor(gray: 1, alpha: 0.95)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
// Fönstrets tre knappar.
for (i, c) in [(0, CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1)), (1, CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1)),
               (2, CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1))] {
    ctx.setFillColor(c)
    ctx.fillEllipse(in: CGRect(x: win.minX + 40 + Double(i) * 46, y: win.maxY - 62, width: 28, height: 28))
}
// Inspelningspricken.
ctx.setFillColor(CGColor(red: 0.95, green: 0.2, blue: 0.25, alpha: 1))
ctx.fillEllipse(in: CGRect(x: win.midX - 75, y: win.midY - 100, width: 150, height: 150))
ctx.setStrokeColor(CGColor(red: 0.95, green: 0.2, blue: 0.25, alpha: 0.35)); ctx.setLineWidth(18)
ctx.strokeEllipse(in: CGRect(x: win.midX - 115, y: win.midY - 140, width: 230, height: 230))
ctx.restoreGState()

// Markören, ovanpå allt.
let arrow = CGMutablePath()
let o = CGPoint(x: tile.minX + 560, y: tile.minY + 330)
let pts: [(Double, Double)] = [(0, 0), (0, -250), (62, -192), (106, -290), (150, -270), (108, -176), (190, -176)]
arrow.move(to: CGPoint(x: o.x + pts[0].0, y: o.y + pts[0].1))
for p in pts.dropFirst() { arrow.addLine(to: CGPoint(x: o.x + p.0, y: o.y + p.1)) }
arrow.closeSubpath()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(gray: 0, alpha: 0.4))
ctx.addPath(arrow); ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.addPath(arrow); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(16); ctx.setLineJoin(.round); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
