// Renders a placeholder app icon in the spirit of the brief: three translucent
// speech bubbles behind a white one with three dots, on a soft glass squircle.
// Drop a real 1024px PNG at icon.png to replace it; make-icon.sh prefers that.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

func bubble(_ rect: CGRect, radius: CGFloat, tail: CGPoint, color: NSColor, alpha: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let tailPath = NSBezierPath()
    tailPath.move(to: CGPoint(x: tail.x - 40, y: rect.minY + 4))
    tailPath.line(to: CGPoint(x: tail.x + 60, y: rect.minY + 4))
    tailPath.line(to: tail)
    tailPath.close()
    path.append(tailPath)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: NSColor.black.withAlphaComponent(0.10).cgColor)
    color.withAlphaComponent(alpha).setFill()
    path.fill()
    ctx.restoreGState()
}

// Squircle background
let bg = NSBezierPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864), xRadius: 200, yRadius: 200)
let gradient = NSGradient(colors: [NSColor(white: 0.985, alpha: 1), NSColor(white: 0.93, alpha: 1)])!
gradient.draw(in: bg, angle: -90)
NSColor(white: 1, alpha: 0.9).setStroke(); bg.lineWidth = 3; bg.stroke()

// Back bubbles — teal, orange, blue
bubble(CGRect(x: 290, y: 470, width: 380, height: 300), radius: 120, tail: CGPoint(x: 330, y: 400),
       color: NSColor(red: 0.20, green: 0.62, blue: 0.55, alpha: 1), alpha: 0.85)
bubble(CGRect(x: 540, y: 430, width: 320, height: 280), radius: 110, tail: CGPoint(x: 820, y: 370),
       color: NSColor(red: 0.98, green: 0.50, blue: 0.28, alpha: 1), alpha: 0.85)
bubble(CGRect(x: 170, y: 300, width: 400, height: 300), radius: 130, tail: CGPoint(x: 440, y: 230),
       color: NSColor(red: 0.30, green: 0.58, blue: 0.95, alpha: 1), alpha: 0.85)
bubble(CGRect(x: 520, y: 240, width: 330, height: 260), radius: 110, tail: CGPoint(x: 800, y: 175),
       color: NSColor(white: 0.97, alpha: 1), alpha: 0.9)

// Front white bubble with three dots
bubble(CGRect(x: 330, y: 380, width: 380, height: 270), radius: 105, tail: CGPoint(x: 400, y: 300),
       color: .white, alpha: 1)
for i in 0..<3 {
    let dot = NSBezierPath(ovalIn: CGRect(x: 420 + CGFloat(i) * 80, y: 490, width: 44, height: 44))
    NSColor(white: 0.40, alpha: 1).setFill(); dot.fill()
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
