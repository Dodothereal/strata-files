import Foundation

/// A contributed palette supplies color choices; native drawing and accessibility stay in ThemeStyle.
nonisolated package struct ThemeDefinition: Decodable, Sendable {
    package let id: String
    package let name: String
    package let order: Int
    package let seed: ThemeRGB
    package let tintStrength: CGFloat
    package let lightShift: CGFloat
    package let darkShift: CGFloat

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, name, comment, order, seed, tintStrength, lightnessShift
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    package init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        guard Set(keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw ThemeCatalog.Invalid("Unknown or missing theme fields")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else {
            throw ThemeCatalog.Invalid("Unsupported theme version")
        }
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        order = try values.decode(Int.self, forKey: .order)
        let comment = try values.decode(String.self, forKey: .comment)
        let channels = try values.decode([Double].self, forKey: .seed)
        let strength = try values.decode(Double.self, forKey: .tintStrength)
        let shift = try values.decode([String: Double].self, forKey: .lightnessShift)
        guard Set(shift.keys) == ["light", "dark"], let light = shift["light"], let dark = shift["dark"] else {
            throw ThemeCatalog.Invalid("Expected light and dark lightness shifts")
        }
        guard id.range(of: "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
              id.count <= 48, id != "system", order > 0, order <= 10_000,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.contains("%"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, comment.count <= 240,
              channels.count == 3, channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              strength.isFinite, (0...1.25).contains(strength),
              light.isFinite, (-0.02...0.04).contains(light),
              dark.isFinite, (-0.12...0.04).contains(dark) else {
            throw ThemeCatalog.Invalid("Invalid theme identity, name or color values")
        }
        seed = ThemeRGB(red: channels[0], green: channels[1], blue: channels[2])
        tintStrength = strength
        lightShift = light
        darkShift = dark
    }
}

nonisolated package enum ThemeCatalog {
    package struct Invalid: Error, CustomStringConvertible {
        package let description: String
        init(_ description: String) { self.description = description }
    }

    package static let bundled: [ColorTheme] = {
        do { return try loadBundled() }
        catch {
            NSLog("Strata could not load its color themes: %@", String(describing: error))
            return []
        }
    }()

    package static func loadBundled() throws -> [ColorTheme] {
        // SwiftPM's accessor finds the bundle beside test executables; packaged apps carry it in Resources.
        let bundle = Bundle.main.url(forResource: "Strata_StrataTheme", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? .module
        guard let folder = bundle.url(forResource: "Themes", withExtension: nil) else {
            throw Invalid("Missing bundled theme folder")
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard !files.isEmpty, files.count <= 128 else { throw Invalid("Expected 1–128 theme files") }
        return try load(files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    /// This same loader validates new files in tests, without changing the application's catalog or preferences.
    package static func load(_ files: [(name: String, data: Data)]) throws -> [ColorTheme] {
        guard files.count <= 128 else { throw Invalid("Too many theme files") }
        var ids = Set<String>(), names = Set<String>(), orders = Set<Int>()
        let themes = try files.map { file in
            guard file.data.count <= 16_384 else { throw Invalid("Theme file is larger than 16 KiB: \(file.name)") }
            let definition = try JSONDecoder().decode(ThemeDefinition.self, from: file.data)
            guard file.name == definition.id + ".json",
                  ids.insert(definition.id).inserted, names.insert(definition.name).inserted,
                  orders.insert(definition.order).inserted else {
                throw Invalid("Theme filename, ID, name and order must be unique: \(file.name)")
            }
            return definition
        }.sorted { $0.order < $1.order }
        return themes.map(ColorTheme.init(definition:))
    }
}
