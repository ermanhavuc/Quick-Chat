// Renders the app icon: a rounded-square gradient tile with a chat bubble and a sparkle.
// Usage: swift scripts/make-icon.swift <output.png>   (1024×1024; see scripts/make-icon.sh)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824×824 body centred on the 1024 canvas, corner radius ≈ 185.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x0E3B43).setFill()
tile.fill()
ctx.restoreGState()

// Tile gradient: deep teal → indigo, lit from the top.
ctx.saveGState()
tile.addClip()
NSGradient(colors: [color(0x1BC5A4), color(0x138A8A), color(0x2B3A8C)], atLocations: [0, 0.5, 1],
           colorSpace: .sRGB)!.draw(in: body, angle: -60)
// Soft highlight at the top.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
ctx.restoreGState()

// Chat bubble with a tail at the bottom left.
let bubbleRect = NSRect(x: 250, y: 330, width: 524, height: 400)
let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 150, yRadius: 150)
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 330, y: 380))
tail.curve(to: NSPoint(x: 262, y: 262), controlPoint1: NSPoint(x: 322, y: 320), controlPoint2: NSPoint(x: 300, y: 282))
tail.curve(to: NSPoint(x: 440, y: 345), controlPoint1: NSPoint(x: 340, y: 270), controlPoint2: NSPoint(x: 400, y: 300))
tail.close()
bubble.append(tail)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
NSColor.white.setFill()
bubble.fill()
ctx.restoreGState()

// Four-point sparkle inside the bubble.
func sparkle(center c: NSPoint, radius r: CGFloat, waist w: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x, y: c.y + r))
    p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
    p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
    p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
    p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
    p.close()
    return p
}
let sparkleFill = NSGradient(colors: [color(0x16B39A), color(0x2B3A8C)])!
let big = sparkle(center: NSPoint(x: 492, y: 530), radius: 128, waist: 22)
sparkleFill.draw(in: big, angle: -60)
let small = sparkle(center: NSPoint(x: 628, y: 640), radius: 50, waist: 9)
sparkleFill.draw(in: small, angle: -60)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
