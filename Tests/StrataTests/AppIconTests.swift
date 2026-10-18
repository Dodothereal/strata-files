import AppKit
import Testing

struct AppIconTests {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources")
    }

    @Test func editableIconKeepsSeparateArtworkAndHidesTheAlignmentReference() throws {
        let source = resources.appending(path: "AppIcon.icon")
        let data = try Data(contentsOf: source.appending(path: "icon.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try #require(manifest["groups"] as? [[String: Any]])
        let layers = groups.flatMap { $0["layers"] as? [[String: Any]] ?? [] }
        let visible = layers.filter { $0["hidden"] as? Bool != true }
        #expect(visible.count >= 3)
        #expect(Set(visible.compactMap { $0["image-name"] as? String }).count >= 3)
        let reference = try #require(layers.first { $0["image-name"] as? String == "Strata.png" })
        #expect(reference["hidden"] as? Bool == true)
        for layer in layers {
            let name = try #require(layer["image-name"] as? String)
            #expect(NSImage(contentsOf: source.appending(path: "Assets").appending(path: name))?.isValid == true)
        }
    }

    @Test func fallbackHasEveryMacIconSizeAndTheBundleNamesTheAdaptiveIcon() throws {
        let fallback = try #require(NSImage(contentsOf: resources.appending(path: "AppIcon.icns")))
        #expect(fallback.isValid)
        #expect(Set(fallback.representations.map(\.pixelsWide)) == [16, 32, 64, 128, 256, 512, 1024])
        #expect(fallback.representations.allSatisfy { $0.pixelsWide == $0.pixelsHigh })
        let info = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: resources.appending(path: "Info.plist")), format: nil) as? [String: Any])
        #expect(info["CFBundleIconName"] as? String == "AppIcon")
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    }
}
