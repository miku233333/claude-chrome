import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else { exit(64) }
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let sourceRepresentation = sourceImage.representations.max(by: {
          $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
      }),
      sourceRepresentation.pixelsWide > 0,
      sourceRepresentation.pixelsHigh > 0
else { exit(65) }

let sourceSize = NSSize(
    width: sourceRepresentation.pixelsWide,
    height: sourceRepresentation.pixelsHigh
)
sourceImage.size = sourceSize

let files: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in files {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { exit(1) }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let targetSize = CGFloat(pixels)
    let bounds = NSRect(x: 0, y: 0, width: targetSize, height: targetSize)
    NSColor.clear.setFill()
    bounds.fill()

    let scale = min(targetSize / sourceSize.width, targetSize / sourceSize.height)
    let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let drawRect = NSRect(
        x: (targetSize - drawSize.width) / 2,
        y: (targetSize - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    sourceImage.draw(
        in: drawRect,
        from: NSRect(origin: .zero, size: sourceSize),
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}
