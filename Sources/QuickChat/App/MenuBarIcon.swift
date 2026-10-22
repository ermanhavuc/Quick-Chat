import AppKit

/// The menu-bar glyph: the app icon's chat bubble with its sparkles cut out, as a template image.
/// The shapes use the app icon's 1024-pt coordinates (scripts/make-icon.swift) so the two stay in step.
/// `dot`: a dot at the top right, set apart from the bubble by a gap (Quick Chat's answer is ready).
enum MenuBarIcon {
    static func make(dot: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // The bubble with its tail spans x 250…774, y 262…730 in icon space.
            let scale: CGFloat = 16 / 524
            let transform = NSAffineTransform()
            transform.translateX(by: (size.width - 524 * scale) / 2, yBy: (size.height - 468 * scale) / 2)
            transform.scale(by: scale)
            transform.translateX(by: -250, yBy: -262)

            let bubble = NSBezierPath(roundedRect: NSRect(x: 250, y: 330, width: 524, height: 400),
                                      xRadius: 150, yRadius: 150)
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 330, y: 380))
            tail.curve(to: NSPoint(x: 262, y: 262), controlPoint1: NSPoint(x: 322, y: 320),
                       controlPoint2: NSPoint(x: 300, y: 282))
            tail.curve(to: NSPoint(x: 440, y: 345), controlPoint1: NSPoint(x: 340, y: 270),
                       controlPoint2: NSPoint(x: 400, y: 300))
            tail.close()
            bubble.append(tail)
            bubble.transform(using: transform as AffineTransform)
            NSColor.black.setFill()
            bubble.fill()

            // Slightly fatter sparkles than the icon's so they survive at menu-bar size.
            let sparkles = sparkle(center: NSPoint(x: 492, y: 530), radius: 140, waist: 34)
            sparkles.append(sparkle(center: NSPoint(x: 640, y: 645), radius: 62, waist: 15))
            sparkles.transform(using: transform as AffineTransform)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            sparkles.fill()

            if dot {
                let center = NSPoint(x: size.width - 3.5, y: size.height - 3.5)
                NSBezierPath(ovalIn: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = dot ? "Quick Chat, answer ready" : "Quick Chat"
        return image
    }

    private static func sparkle(center c: NSPoint, radius r: CGFloat, waist w: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y + r))
        p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w),
                controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
        p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w),
                controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
        p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w),
                controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
        p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w),
                controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
        p.close()
        return p
    }
}
