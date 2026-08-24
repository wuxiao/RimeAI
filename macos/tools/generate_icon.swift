import AppKit
import CoreText
import CoreGraphics
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("usage: generate_icon.swift OUTPUT.pdf [input-method|menu]\n", stderr)
    exit(2)
}

enum IconVariant: String {
    case inputMethod = "input-method"
    case menu
}

let variantName = CommandLine.arguments.count == 3
    ? CommandLine.arguments[2]
    : IconVariant.inputMethod.rawValue
guard let variant = IconVariant(rawValue: variantName) else {
    fputs("error: expected icon variant input-method or menu\n", stderr)
    exit(2)
}

let canvasSize: CGSize
let inset: CGFloat
let corner: CGFloat
switch variant {
case .inputMethod:
    // Preserve the wider badge used by the Input Sources settings surface.
    canvasSize = CGSize(width: 24, height: 18)
    inset = 1
    corner = 5
case .menu:
    // Text Input Sources reserves space from the menu icon's intrinsic size.
    // Match the system 16 x 16 pt square contract and let the rounded outline
    // reach each edge, as current Apple input-mode template icons do.
    canvasSize = CGSize(width: 16, height: 16)
    inset = 0
    corner = 4
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let consumer = CGDataConsumer(url: outputURL) else {
    fputs("cannot create icon output\n", stderr)
    exit(1)
}

var mediaBox = CGRect(origin: .zero, size: canvasSize)
guard let context = CGContext(
    consumer: consumer,
    mediaBox: &mediaBox,
    nil
) else {
    fputs("cannot create PDF context\n", stderr)
    exit(1)
}

context.beginPDFPage(nil)

let backgroundPath = CGPath(
    roundedRect: CGRect(
        x: inset, y: inset,
        width: canvasSize.width - inset * 2,
        height: canvasSize.height - inset * 2
    ),
    cornerWidth: corner,
    cornerHeight: corner,
    transform: nil
)

// Cut out "R" from the background. InputMethodKit treats this PDF as a
// template image and uses only its alpha mask, so an opaque white glyph would
// disappear into the rounded rectangle after system tinting.
let line = CTLineCreateWithAttributedString(NSAttributedString(
    string: "R",
    attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .bold),
    ]
))
let rawGlyphPath = CGMutablePath()
for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
    let font = (CTRunGetAttributes(run) as NSDictionary)[
        kCTFontAttributeName
    ] as! CTFont

    let glyphCount = CTRunGetGlyphCount(run)
    var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
    var positions = Array(repeating: CGPoint.zero, count: glyphCount)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

    for index in 0..<glyphCount {
        guard let glyphPath = CTFontCreatePathForGlyph(
            font,
            glyphs[index],
            nil
        ) else {
            continue
        }
        let transform = CGAffineTransform(
            translationX: positions[index].x,
            y: positions[index].y
        )
        rawGlyphPath.addPath(glyphPath, transform: transform)
    }
}

let glyphBounds = rawGlyphPath.boundingBoxOfPath
guard !glyphBounds.isNull, !glyphBounds.isEmpty else {
    fputs("cannot create icon glyph path\n", stderr)
    exit(1)
}
// The upper bowl makes "R" look top-heavy even when its path bounds are
// mathematically centered. Shift it down slightly for optical centering.
let glyphOpticalYOffset: CGFloat = -0.5
let centerTransform = CGAffineTransform(
    translationX: (canvasSize.width - glyphBounds.width) / 2
        - glyphBounds.minX,
    y: (canvasSize.height - glyphBounds.height) / 2 - glyphBounds.minY
        + glyphOpticalYOffset
)
let maskPath = CGMutablePath()
maskPath.addPath(backgroundPath)
maskPath.addPath(rawGlyphPath, transform: centerTransform)

context.setFillColor(NSColor(calibratedWhite: 0.35, alpha: 1.0).cgColor)
context.addPath(maskPath)
context.drawPath(using: .eoFill)
context.endPDFPage()
context.closePDF()
