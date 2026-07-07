#!/usr/bin/env swift
// Renders Resources/AppIcon.icns: a Big Sur-style rounded-square badge with
// an original 3x3 app-grid glyph (deliberately not Apple's rocket artwork —
// that's their trademark, not ours to reuse). Run with:
//   swift Scripts/generate_icon.swift
import AppKit

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Big Sur-style squircle background, cool blue-violet gradient.
    let cornerRadius = size * 0.2256
    let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.42, green: 0.45, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.29, green: 0.20, blue: 0.75, alpha: 1.0),
    ])
    gradient?.draw(in: bgPath, angle: -90)

    // 3x3 grid of rounded squares, evoking the app grid without copying
    // Apple's actual Launchpad iconography.
    let gridInset = size * 0.20
    let gridArea = size - gridInset * 2
    let cell = gridArea / 3
    let dotSize = cell * 0.62
    let dotRadius = dotSize * 0.28

    NSColor.white.withAlphaComponent(0.95).set()
    for row in 0..<3 {
        for col in 0..<3 {
            let x = gridInset + CGFloat(col) * cell + (cell - dotSize) / 2
            let y = gridInset + CGFloat(row) * cell + (cell - dotSize) / 2
            let dotRect = NSRect(x: x, y: y, width: dotSize, height: dotSize)
            NSBezierPath(roundedRect: dotRect, xRadius: dotRadius, yRadius: dotRadius).fill()
        }
    }

    image.unlockFocus()
    return image
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let projectRoot = scriptDir.deletingLastPathComponent()
let iconsetURL = projectRoot.appendingPathComponent("Resources/AppIcon.iconset")
let icnsURL = projectRoot.appendingPathComponent("Resources/AppIcon.icns")

try? fm.removeItem(at: iconsetURL)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (pixelSize, name) in sizes {
    let image = makeIcon(size: CGFloat(pixelSize))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to rasterize \(name)")
    }
    let fileURL = iconsetURL.appendingPathComponent("\(name).png")
    try png.write(to: fileURL)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

try? fm.removeItem(at: iconsetURL)

print(process.terminationStatus == 0 ? "Wrote \(icnsURL.path)" : "iconutil failed")
