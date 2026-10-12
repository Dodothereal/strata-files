import SwiftUI

/// Settings ▸ Appearance: light or dark, how tightly rows are packed, and how big file names are.
struct AppearanceSettings: View {
    @State private var theme = Prefs.theme
    @State private var density = Prefs.density
    @State private var size = Prefs.nameTextSize

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: Binding(get: { theme }, set: { theme = $0; Prefs.theme = $0 })) {
                    Text("Match the System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Files") {
                Picker("Density", selection: Binding(get: { density }, set: { density = $0; Prefs.density = $0 })) {
                    Text("Compact").tag(0)
                    Text("Regular").tag(1)
                    Text("Spacious").tag(2)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Text size")
                    Slider(value: Binding(get: { size }, set: { size = $0.rounded(); Prefs.nameTextSize = $0.rounded() }), in: 11...16, step: 1) {
                        Text("Text size")
                    } minimumValueLabel: {
                        Text("A").font(.system(size: 10))
                    } maximumValueLabel: {
                        Text("A").font(.system(size: 16))
                    }
                    Text("\(Int(size)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                Text("Quarterly Report.pdf")
                    .font(.system(size: size))
                    .padding(.vertical, [2.0, 5.0, 9.0][min(max(density, 0), 2)])
                    .accessibilityLabel("Preview of a file name at this size")
                Text("Applies to the list, columns and icons in every window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
