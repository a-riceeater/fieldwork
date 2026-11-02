import AppKit
import SwiftUI

/// Whether the app follows the Mac's light or dark setting or overrides it.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Nil leaves the app following the Mac.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The app-wide appearance choice, a per-user preference shared by every window.
@MainActor
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()
    private static let key = "FieldworkAppearance"

    private let preferences: UserDefaults

    @Published var mode: AppearanceMode {
        didSet {
            preferences.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        mode = preferences.string(forKey: Self.key).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    func apply() {
        NSApp.appearance = mode.appearance
    }
}

/// The toolbar's appearance menu; its icon shows the current choice.
struct AppearanceMenu: View {
    @ObservedObject private var settings = AppearanceSettings.shared

    var body: some View {
        Menu {
            Picker("Appearance", selection: $settings.mode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Appearance", systemImage: settings.mode.systemImage)
        }
        .help("Use the Mac's appearance, or always light or dark (View › Appearance)")
    }
}
