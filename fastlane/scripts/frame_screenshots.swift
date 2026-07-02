#!/usr/bin/env swift

import AppKit
import Foundation

struct ScreenshotDesign {
    let id: String
    let headline: String
    let subcopy: String
    let background: NSColor
    let accent: NSColor
}

extension NSColor {
    convenience init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        self.init(
            calibratedRed: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }
}

let designs = [
    ScreenshotDesign(
        id: "01-Today",
        headline: "Open. Check.\nMove on.",
        subcopy: "A calm daily checklist for repeatable routines.",
        background: NSColor(hex: "#FAF6ED"),
        accent: NSColor(hex: "#D9472F")
    ),
    ScreenshotDesign(
        id: "02-Groups",
        headline: "Keep routines\ntidy",
        subcopy: "Group tasks by morning, home, planning, or anything else.",
        background: NSColor(hex: "#EAF4EF"),
        accent: NSColor(hex: "#0F766E")
    ),
    ScreenshotDesign(
        id: "03-Reminders",
        headline: "Never miss\nthe small stuff",
        subcopy: "Add reminders for the tasks that need a nudge.",
        background: NSColor(hex: "#EEF2FF"),
        accent: NSColor(hex: "#4F46E5")
    ),
    ScreenshotDesign(
        id: "04-Sync",
        headline: "Your list,\neverywhere",
        subcopy: "Offline-first on iPhone, synced with web when signed in.",
        background: NSColor(hex: "#ECF7FA"),
        accent: NSColor(hex: "#0E7490")
    )
]

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("Usage: frame_screenshots.swift <screenshots-directory>\n".data(using: .utf8)!)
    exit(2)
}

let rootURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fileManager = FileManager.default

guard let enumerator = fileManager.enumerator(
    at: rootURL,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
) else {
    FileHandle.standardError.write("Unable to read screenshots directory: \(rootURL.path)\n".data(using: .utf8)!)
    exit(1)
}

var framedCount = 0

for case let fileURL as URL in enumerator {
    guard fileURL.pathExtension.lowercased() == "png" else { continue }
    guard let design = designs.first(where: { fileURL.lastPathComponent.contains($0.id) }) else { continue }

    do {
        try frameScreenshot(at: fileURL, design: design)
        framedCount += 1
        print("Framed \(fileURL.path)")
    } catch {
        FileHandle.standardError.write("Failed to frame \(fileURL.path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

guard framedCount > 0 else {
    FileHandle.standardError.write("No matching screenshots found under \(rootURL.path)\n".data(using: .utf8)!)
    exit(1)
}

func frameScreenshot(at fileURL: URL, design: ScreenshotDesign) throws {
    let data = try Data(contentsOf: fileURL)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        throw NSError(domain: "FrameScreenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG could not be decoded"])
    }

    let sourceSize = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    let sourceImage = NSImage(size: sourceSize)
    sourceImage.addRepresentation(bitmap)

    let canvasSize = sourceSize
    guard let outputBitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width),
        pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "FrameScreenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bitmap context could not be created"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outputBitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawBackground(size: canvasSize, design: design)
    drawCopy(size: canvasSize, design: design)
    drawPhone(sourceImage: sourceImage, canvasSize: canvasSize)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = outputBitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FrameScreenshots", code: 3, userInfo: [NSLocalizedDescriptionKey: "Framed PNG could not be encoded"])
    }

    try png.write(to: fileURL, options: .atomic)
}

func drawBackground(size: NSSize, design: ScreenshotDesign) {
    design.background.setFill()
    NSRect(origin: .zero, size: size).fill()

    let bandHeight = size.height * 0.045
    let bandRect = NSRect(x: 0, y: 0, width: size.width, height: bandHeight)
    design.accent.withAlphaComponent(0.9).setFill()
    bandRect.fill()
}

func drawCopy(size: NSSize, design: ScreenshotDesign) {
    let textColor = NSColor(hex: "#141824")
    let headlineFont = NSFont.systemFont(ofSize: min(94, size.width * 0.073), weight: .heavy)
    let subcopyFont = NSFont.systemFont(ofSize: min(37, size.width * 0.029), weight: .medium)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 2

    let headlineAttributes: [NSAttributedString.Key: Any] = [
        .font: headlineFont,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph
    ]
    let subcopyAttributes: [NSAttributedString.Key: Any] = [
        .font: subcopyFont,
        .foregroundColor: textColor.withAlphaComponent(0.78),
        .paragraphStyle: paragraph
    ]

    let headlineRect = rectFromTop(
        x: size.width * 0.09,
        y: size.height * 0.058,
        width: size.width * 0.82,
        height: size.height * 0.145,
        canvasHeight: size.height
    )
    let subcopyRect = rectFromTop(
        x: size.width * 0.15,
        y: size.height * 0.218,
        width: size.width * 0.70,
        height: size.height * 0.070,
        canvasHeight: size.height
    )

    NSAttributedString(string: design.headline, attributes: headlineAttributes).draw(
        with: headlineRect,
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    NSAttributedString(string: design.subcopy, attributes: subcopyAttributes).draw(
        with: subcopyRect,
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
}

func drawPhone(sourceImage: NSImage, canvasSize: NSSize) {
    let aspect = sourceImage.size.height / sourceImage.size.width
    let frameInset = max(28, canvasSize.width * 0.026)
    let phoneTop = canvasSize.height * 0.255
    let bottomMargin = canvasSize.height * 0.035
    let maxOuterWidth = canvasSize.width * 0.78
    let maxOuterHeight = canvasSize.height - phoneTop - bottomMargin
    let screenWidth = min(maxOuterWidth - frameInset * 2, (maxOuterHeight - frameInset * 2) / aspect)
    let screenHeight = screenWidth * aspect
    let outerWidth = screenWidth + frameInset * 2
    let outerHeight = screenHeight + frameInset * 2
    let outerRect = rectFromTop(
        x: (canvasSize.width - outerWidth) / 2,
        y: phoneTop,
        width: outerWidth,
        height: outerHeight,
        canvasHeight: canvasSize.height
    )
    let screenRect = outerRect.insetBy(dx: frameInset, dy: frameInset)

    let sideButtonWidth = max(8, outerWidth * 0.010)
    let sideButtonRadius = sideButtonWidth / 2
    NSColor.black.withAlphaComponent(0.45).setFill()
    NSBezierPath(
        roundedRect: NSRect(
            x: outerRect.minX - sideButtonWidth,
            y: outerRect.maxY - outerHeight * 0.30,
            width: sideButtonWidth,
            height: outerHeight * 0.11
        ),
        xRadius: sideButtonRadius,
        yRadius: sideButtonRadius
    ).fill()
    NSBezierPath(
        roundedRect: NSRect(
            x: outerRect.maxX,
            y: outerRect.maxY - outerHeight * 0.36,
            width: sideButtonWidth,
            height: outerHeight * 0.15
        ),
        xRadius: sideButtonRadius,
        yRadius: sideButtonRadius
    ).fill()

    let shadow = NSShadow()
    shadow.shadowBlurRadius = canvasSize.width * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -canvasSize.height * 0.010)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.set()

    NSColor(hex: "#090B10").setFill()
    NSBezierPath(
        roundedRect: outerRect,
        xRadius: outerWidth * 0.115,
        yRadius: outerWidth * 0.115
    ).fill()
    NSShadow().set()

    NSColor(hex: "#111318").setStroke()
    let rimPath = NSBezierPath(
        roundedRect: outerRect.insetBy(dx: 3, dy: 3),
        xRadius: outerWidth * 0.108,
        yRadius: outerWidth * 0.108
    )
    rimPath.lineWidth = max(2, canvasSize.width * 0.003)
    rimPath.stroke()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(
        roundedRect: screenRect,
        xRadius: screenWidth * 0.075,
        yRadius: screenWidth * 0.075
    ).addClip()
    sourceImage.draw(
        in: screenRect,
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    let islandWidth = screenWidth * 0.30
    let islandHeight = screenWidth * 0.078
    let islandRect = NSRect(
        x: screenRect.midX - islandWidth / 2,
        y: screenRect.maxY - islandHeight - screenWidth * 0.034,
        width: islandWidth,
        height: islandHeight
    )
    NSColor.black.setFill()
    NSBezierPath(
        roundedRect: islandRect,
        xRadius: islandHeight / 2,
        yRadius: islandHeight / 2
    ).fill()
}

func rectFromTop(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, canvasHeight: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasHeight - y - height, width: width, height: height)
}
