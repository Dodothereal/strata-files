import AppKit
import Testing
@testable import StrataTheme

struct ThemeCatalogTests {
    private func file(id: String = "meadow", name: String = "Meadow", order: Int = 150,
                      changing: [String: Any] = [:]) throws -> (name: String, data: Data) {
        var values: [String: Any] = [
            "version": 1, "id": id, "name": name, "comment": "Color theme: soft yellow-green",
            "order": order, "seed": [0.45, 0.60, 0.25], "tintStrength": 0.5,
            "lightnessShift": ["light": 0.0, "dark": -0.02],
        ]
        values.merge(changing) { _, new in new }
        return (id + ".json", try JSONSerialization.data(withJSONObject: values))
    }

    @Test func bundledThemesAreValidAndEveryFileIsAvailableInSettings() throws {
        let themes = try ThemeCatalog.loadBundled()
        #expect(!themes.isEmpty)
        #expect(ColorTheme.allCases == [.system] + themes)
        for theme in themes {
            #expect(ColorTheme(rawValue: theme.rawValue) == theme)
            #expect(!theme.title.isEmpty)
        }
        for id in ["graphite", "blue", "green", "purple", "sand", "teal", "rose", "amber",
                   "slate", "sage", "coral", "plum", "ice", "midnight"] {
            #expect(themes.contains { $0.rawValue == id })
        }
    }

    @Test func anUnlistedThemeLoadsWithoutChangingSwiftAndKeepsItsOwnColors() throws {
        let themes = try ThemeCatalog.load([file(order: 160), file(id: "dusk", name: "Dusk", order: 150)])
        #expect(themes.map(\.rawValue) == ["dusk", "meadow"])
        let meadow = try #require(themes.last)
        #expect(meadow.title == "Meadow")
        #expect(meadow.seed == ThemeRGB(red: 0.45, green: 0.60, blue: 0.25))
        for dark in [false, true] {
            #expect(meadow.surface(.content, dark: dark)
                    == meadow.seed.surface(.content, dark: dark, tintStrength: 0.5, brightnessShift: dark ? -0.02 : 0))
        }
        #expect(ColorTheme(rawValue: "meadow") == nil, "An injected catalog must not change the application catalog.")
    }

    @Test func invalidColorsSchemaAndIdentityFailBeforeAThemeIsPublished() throws {
        let changes: [[String: Any]] = [
            ["version": 2], ["extra": "typo"], ["seed": []], ["seed": [0.5, 0.5]],
            ["seed": [0.5, 0.5, 0.5, 0.5]], ["seed": [-0.01, 0.5, 0.5]], ["seed": [1.01, 0.5, 0.5]],
            ["seed": ["red", "green", "blue"]], ["seed": NSNull()],
            ["tintStrength": -0.01], ["tintStrength": 1.26],
            ["lightnessShift": ["light": -0.03, "dark": 0]],
            ["lightnessShift": ["light": 0, "dark": -0.13]],
            ["lightnessShift": ["light": 0.05, "dark": 0.05]],
            ["lightnessShift": ["light": 0]], ["id": "system"], ["id": "../escape"],
            ["lightnessShift": ["light": 0, "dark": 0, "dakr": -0.02]],
            ["id": "Meadow"], ["id": ""], ["name": " "], ["name": " Meadow"],
            ["name": "Two\nLines"], ["name": "%@"], ["name": String(repeating: "a", count: 41)],
            ["comment": " "], ["order": 0], ["order": 10_001],
        ]
        for change in changes {
            let input = try file(changing: change)
            #expect(throws: (any Error).self, "\(change)") { try ThemeCatalog.load([input]) }
        }
        for data in [Data(), Data("{".utf8), Data(repeating: 32, count: 16_385)] {
            #expect(throws: (any Error).self) { try ThemeCatalog.load([("meadow.json", data)]) }
        }
        let input = try file()
        #expect(throws: (any Error).self) { try ThemeCatalog.load([("other.json", input.data)]) }
        #expect(throws: (any Error).self) { try ThemeCatalog.load(Array(repeating: input, count: 129)) }
    }

    @Test func duplicateIdsNamesAndOrdersCannotSilentlyHideAContribution() throws {
        let first = try file()
        for duplicate in [try file(name: "Other", order: 160),
                          try file(id: "other", order: 160),
                          try file(id: "other", name: "Other")] {
            #expect(throws: (any Error).self) { try ThemeCatalog.load([first, duplicate]) }
        }
    }
}
