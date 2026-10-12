import AppKit
import XCTest
@testable import RimeAIInputMethod

final class InputSourceIconContractTests: XCTestCase {
    func testInputMethodConnectionNameUsesModernIMKFallbackContract() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNil(info["InputMethodConnectionName"])

        let bundleIdentifier = try XCTUnwrap(
            info["CFBundleIdentifier"] as? String
        )
        XCTAssertEqual(
            RimeAIInputMethodServerConfiguration.connectionName(
                for: bundleIdentifier
            ),
            "fun.wwcn.inputmethod.RimeAI.Connection"
        )
    }

    func testPackagedIconsUseTheirSurfaceSpecificCanvas() throws {
        let inputMethodIconURL = try XCTUnwrap(
            Bundle.main.url(forResource: "RimeAI", withExtension: "pdf")
        )
        let inputMethodIcon = try XCTUnwrap(NSImage(contentsOf: inputMethodIconURL))
        XCTAssertEqual(inputMethodIcon.size.width, 24, accuracy: 0.001)
        XCTAssertEqual(inputMethodIcon.size.height, 18, accuracy: 0.001)
        let inputMethodVisibleBounds = try visibleBounds(
            of: inputMethodIconURL,
            scale: 4
        )
        XCTAssertEqual(inputMethodVisibleBounds.minX, 4)
        XCTAssertEqual(inputMethodVisibleBounds.minY, 4)
        XCTAssertEqual(inputMethodVisibleBounds.width, 88)
        XCTAssertEqual(inputMethodVisibleBounds.height, 64)

        let menuIconURL = try XCTUnwrap(
            Bundle.main.url(forResource: "RimeAIMenu", withExtension: "pdf")
        )
        let menuIcon = try XCTUnwrap(NSImage(contentsOf: menuIconURL))
        XCTAssertEqual(menuIcon.size.width, 22, accuracy: 0.001)
        XCTAssertEqual(menuIcon.size.height, 16, accuracy: 0.001)

        let visibleBounds = try visibleBounds(of: menuIconURL, scale: 4)
        XCTAssertEqual(visibleBounds.minX, 0)
        XCTAssertEqual(visibleBounds.minY, 0)
        XCTAssertEqual(visibleBounds.width, 88)
        XCTAssertEqual(visibleBounds.height, 64)
    }

    func testInputSourceIconIsExplicitlyConfiguredAsTemplate() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["TISIconIsTemplate"] as? Bool, true)
        XCTAssertEqual(info["tsInputMethodIconFileKey"] as? String, "RimeAI.pdf")

        let component = try XCTUnwrap(info["ComponentInputModeDict"] as? [String: Any])
        let modes = try XCTUnwrap(component["tsInputModeListKey"] as? [String: Any])
        let primary = try XCTUnwrap(
            modes["fun.wwcn.inputmethod.RimeAI.Primary"] as? [String: Any]
        )
        XCTAssertEqual(
            primary["tsInputModeMenuIconFileKey"] as? String,
            "RimeAIMenu.pdf"
        )
        XCTAssertEqual(
            primary["tsInputModeAlternateMenuIconFileKey"] as? String,
            "RimeAIMenu.pdf"
        )
        XCTAssertEqual(primary["tsInputModePaletteIconFileKey"] as? String, "RimeAI.pdf")
    }

    private func visibleBounds(of url: URL, scale: Int) throws -> CGRect {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let mediaBox = page.getBoxRect(.mediaBox)
        let width = Int(mediaBox.width) * scale
        let height = Int(mediaBox.height) * scale
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.drawPDFPage(page)
        }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * bytesPerRow + x * 4 + 3] >= 128 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        XCTAssertGreaterThanOrEqual(maxX, 0)
        XCTAssertGreaterThanOrEqual(maxY, 0)
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}
