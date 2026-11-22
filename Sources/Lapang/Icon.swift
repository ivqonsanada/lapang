#if DEBUG
import AppKit

/// The app icon, drawn in code so it can change with the app: the window's
/// capacity bar (used, purgeable, unused) on a light tile, with the unused
/// part the longest. A first draft until the owner picks a concept.
enum AppIcon {
    /// `Lapang --write-icon=<folder>`: writes <folder>/AppIcon.iconset.
    static var folder: URL? {
        CommandLine.arguments
            .first { $0.hasPrefix("--write-icon=") }
            .map { URL(fileURLWithPath: String($0.dropFirst("--write-icon=".count)), isDirectory: true) }
    }

    static func writeIconSet(to folder: URL) throws {
        let set = folder.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png(pixels).write(to: set.appending(path: name))
            }
        }
    }

    static func png(_ pixels: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    /// Apple's macOS icon grid: an 824-point tile in a 1024 canvas, corner
    /// radius about 185.
    static func draw(in size: CGFloat) {
        let unit = size / 1024
        let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)

        // A soft drop shadow under the tile, as the system icons have.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 18 * unit
        shadow.shadowOffset = NSSize(width: 0, height: -8 * unit)
        shadow.set()
        NSColor(white: 0.97, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        let light = NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.91, alpha: 1)])
        light?.draw(in: shape, angle: -90)

        // The bar: one capsule across the tile, split in three.
        let barHeight = 150 * unit
        let bar = NSRect(x: 172 * unit, y: 512 * unit - barHeight / 2, width: 680 * unit, height: barHeight)
        let capsule = NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        let gap = 12 * unit
        let used = bar.width * 0.30
        let purgeable = bar.width * 0.14
        NSColor(calibratedWhite: 0.62, alpha: 1).setFill()
        NSRect(x: bar.minX, y: bar.minY, width: used, height: bar.height).fill()
        NSColor(calibratedRed: 0.55, green: 0.83, blue: 0.62, alpha: 1).setFill()
        NSRect(x: bar.minX + used + gap, y: bar.minY, width: purgeable, height: bar.height).fill()
        NSColor(calibratedRed: 0.16, green: 0.68, blue: 0.36, alpha: 1).setFill()
        NSRect(x: bar.minX + used + purgeable + 2 * gap, y: bar.minY, width: bar.width, height: bar.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
