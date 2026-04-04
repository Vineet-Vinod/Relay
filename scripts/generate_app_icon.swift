import AppKit

struct Palette {
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let frame: NSColor
    let prompt: NSColor
    let underscore: NSColor
}

let outputDirectory = URL(fileURLWithPath: "Relay/Relay/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let canvasSize = CGSize(width: 1024, height: 1024)

let standardPalette = Palette(
    backgroundTop: NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.22, alpha: 1.0),
    backgroundBottom: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1.0),
    frame: NSColor(calibratedRed: 0.20, green: 0.53, blue: 0.98, alpha: 1.0),
    prompt: NSColor(calibratedWhite: 0.96, alpha: 1.0),
    underscore: NSColor(calibratedRed: 0.40, green: 0.72, blue: 1.0, alpha: 1.0)
)

let darkPalette = Palette(
    backgroundTop: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.15, alpha: 1.0),
    backgroundBottom: NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.07, alpha: 1.0),
    frame: NSColor(calibratedRed: 0.29, green: 0.61, blue: 1.0, alpha: 1.0),
    prompt: NSColor(calibratedWhite: 0.98, alpha: 1.0),
    underscore: NSColor(calibratedRed: 0.54, green: 0.79, blue: 1.0, alpha: 1.0)
)

let tintedPalette = Palette(
    backgroundTop: NSColor(calibratedWhite: 0.18, alpha: 1.0),
    backgroundBottom: NSColor(calibratedWhite: 0.08, alpha: 1.0),
    frame: NSColor(calibratedWhite: 0.90, alpha: 1.0),
    prompt: NSColor(calibratedWhite: 1.0, alpha: 1.0),
    underscore: NSColor(calibratedWhite: 0.80, alpha: 1.0)
)

func makeBitmap(size: CGSize) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Unable to create bitmap")
    }

    rep.size = size
    return rep
}

func drawBackground(in rect: CGRect, palette: Palette) {
    let gradient = NSGradient(
        starting: palette.backgroundTop,
        ending: palette.backgroundBottom
    )

    gradient?.draw(in: NSBezierPath(rect: rect), angle: -90)
}

func drawRouteFrame(in rect: CGRect, color: NSColor) {
    let inset: CGFloat = 208
    let radius: CGFloat = 72
    let segment: CGFloat = 188
    let lineWidth: CGFloat = 48

    let left = rect.minX + inset
    let right = rect.maxX - inset
    let top = rect.maxY - inset
    let bottom = rect.minY + inset

    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = lineWidth

    path.move(to: CGPoint(x: left + segment, y: top))
    path.line(to: CGPoint(x: right - radius, y: top))
    path.appendArc(
        withCenter: CGPoint(x: right - radius, y: top - radius),
        radius: radius,
        startAngle: 90,
        endAngle: 0,
        clockwise: true
    )
    path.line(to: CGPoint(x: right, y: bottom + segment))

    path.move(to: CGPoint(x: right - segment, y: bottom))
    path.line(to: CGPoint(x: left + radius, y: bottom))
    path.appendArc(
        withCenter: CGPoint(x: left + radius, y: bottom + radius),
        radius: radius,
        startAngle: 270,
        endAngle: 180,
        clockwise: true
    )
    path.line(to: CGPoint(x: left, y: top - segment))

    color.setStroke()
    path.stroke()
}

func drawPrompt(in rect: CGRect, promptColor: NSColor, underscoreColor: NSColor) {
    let groupWidth: CGFloat = 430
    let groupHeight: CGFloat = 250
    let groupOriginX = rect.midX - groupWidth / 2
    let groupOriginY = rect.midY - groupHeight / 2

    let chevron = NSBezierPath()
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.lineWidth = 54
    chevron.move(to: CGPoint(x: groupOriginX + 82, y: groupOriginY + 183))
    chevron.line(to: CGPoint(x: groupOriginX + 208, y: groupOriginY + 125))
    chevron.line(to: CGPoint(x: groupOriginX + 82, y: groupOriginY + 67))
    promptColor.setStroke()
    chevron.stroke()

    let underscore = NSBezierPath(
        roundedRect: CGRect(x: groupOriginX + 258, y: groupOriginY + 36, width: 148, height: 44),
        xRadius: 22,
        yRadius: 22
    )
    underscoreColor.setFill()
    underscore.fill()
}

func writeIcon(named fileName: String, palette: Palette) throws {
    let bitmap = makeBitmap(size: canvasSize)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create graphics context")
    }
    NSGraphicsContext.current = context

    let rect = CGRect(origin: .zero, size: canvasSize)
    NSColor.black.setFill()
    rect.fill()
    drawBackground(in: rect, palette: palette)
    drawRouteFrame(in: rect, color: palette.frame)
    drawPrompt(in: rect, promptColor: palette.prompt, underscoreColor: palette.underscore)

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode PNG")
    }

    try data.write(to: outputDirectory.appendingPathComponent(fileName))
}

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try writeIcon(named: "relay-icon.png", palette: standardPalette)
    try writeIcon(named: "relay-icon-dark.png", palette: darkPalette)
    try writeIcon(named: "relay-icon-tinted.png", palette: tintedPalette)
    print("Generated Relay app icons in \(outputDirectory.path)")
} catch {
    fputs("Failed to generate app icons: \(error)\n", stderr)
    exit(1)
}
