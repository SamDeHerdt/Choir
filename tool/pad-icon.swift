// Centres a source image on a transparent 1024 canvas at Apple's icon margin.
import AppKit
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else { print("usage: pad-icon <in> <out>"); exit(1) }
let canvas: CGFloat = 1024, inner: CGFloat = 840
let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
src.draw(in: NSRect(x: (canvas - inner) / 2, y: (canvas - inner) / 2, width: inner, height: inner),
         from: .zero, operation: .sourceOver, fraction: 1)
out.unlockFocus()
guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: args[2]))
