import XCTest
import UIKit
import CoreText

@MainActor
final class KeyboardTypographyTests: XCTestCase {
    func testRecordPublicFontResolution() throws {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceIdiom: .phone),
            UITraitCollection(verticalSizeClass: .regular)
        ])
        let metrics = KeyboardTheme.metrics(for: CGSize(width: 440, height: 253), traitCollection: traits,
                                            screenSize: CGSize(width: 440, height: 956))
        for (role, size) in [("letter", metrics.characterFontSize), ("symbol", metrics.symbolFontSize),
                             ("mode", metrics.modeSwitchFontSize), ("suggestion", metrics.suggestionFontSize)] {
            let font = UIFont.systemFont(ofSize: size, weight: .regular)
            let fallback = CTFontCreateForString(font as CTFont, "বাংলা" as CFString, CFRange(location: 0, length: 5))
            print("OBADH-FONT \(role): family=\(font.familyName) name=\(font.fontName) size=\(font.pointSize) traits=\(font.fontDescriptor.symbolicTraits.rawValue) Bengali=\(CTFontCopyPostScriptName(fallback))")
            XCTAssertEqual(font.pointSize, size)
        }
    }

    // Opt-in diagnostic atlas for image matching, not a font-family assertion.
    // The atlas uses the same public UIFont API as the shipping keyboard.
    // A screenshot match cannot establish an OS API contract.
    func testExportFontAtlasWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["OBADH_FONT_ATLAS"] == "1" else { return }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/font-audit/atlas")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let letters = Array("qwertyuiopasdfghjklzxcvbnm123")
        var manifest: [[String: String]] = []
        for name in ["system"] {
            for step in 80...104 {
                let size = CGFloat(step) / 4
                let font = UIFont.systemFont(ofSize: size, weight: .regular)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: letters.count * 44, height: 60), format: format)
                let image = renderer.image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: letters.count * 44, height: 60))
                    for (i, letter) in letters.enumerated() {
                        (String(letter) as NSString).draw(at: CGPoint(x: i * 44 + 8, y: 8),
                            withAttributes: [.font: font, .foregroundColor: UIColor.black])
                    }
                }
                let file = "\(name)-\(step).png"
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(file))
                manifest.append(["file": file, "requested": name, "resolved": font.fontName, "size": "\(size)"])
            }
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"))
        print("OBADH-FONT-ATLAS \(directory.path)")
    }
    func testExportWordAtlasWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["OBADH_FONT_ATLAS"] == "1" else { return }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/font-audit/words")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let words = ["123", "I", "my", "there", "বাংলা"]
        for step in 48...112 {
            let font = UIFont.systemFont(ofSize: CGFloat(step) / 4, weight: .regular)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 60), format: format)
            let image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 60))
                for (i, word) in words.enumerated() {
                    (word as NSString).draw(at: CGPoint(x: i * 80 + 8, y: 8),
                        withAttributes: [.font: font, .foregroundColor: UIColor.black])
                }
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("system-\(step).png"))
        }
    }

}
