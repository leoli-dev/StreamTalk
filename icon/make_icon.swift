import AppKit

// Render a 1024×1024 macOS-style app icon: a rounded "squircle" with a
// blue→purple gradient and a white waveform glyph.

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// transparent canvas
NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// rounded square (Apple macOS icon grid: ~9% inset, ~22.37% corner radius)
let inset: CGFloat = size * 0.085
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.95, alpha: 1),  // indigo
    NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1),  // purple
])!
gradient.draw(in: squircle, angle: -90)

// white waveform glyph, tinted from the SF Symbol template
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    let r = NSRect(origin: .zero, size: image.size)
    image.draw(in: r)
    r.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

let cfg = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
if let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let white = tinted(base, .white)
    let s = white.size
    let glyph = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2,
                       width: s.width, height: s.height)
    white.draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1)
}

img.unlockFocus()

// write PNG
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render\n", stderr); exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
