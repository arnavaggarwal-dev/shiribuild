import SwiftUI

/// Persisted haptics/audio preferences. Both default to enabled (a missing
/// UserDefaults key must read as "on", so this uses `object(forKey:)` rather
/// than the plain `bool(forKey:)` — which defaults missing keys to `false`
/// and would silently mute everyone on first launch).
enum AppSettings {
    private static let hapticsKey = "com.arnavaggarwal.shiritori.hapticsEnabled"
    private static let audioKey = "com.arnavaggarwal.shiritori.audioEnabled"

    static var hapticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hapticsKey) }
    }

    static var audioEnabled: Bool {
        get { UserDefaults.standard.object(forKey: audioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: audioKey) }
    }
}

/// Settings screen — only reachable from the lobby (main screen), via the
/// gear icon. Deliberately not exposed mid-game: changing these settings
/// while a round is running isn't a scenario worth designing for.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hapticsOn = AppSettings.hapticsEnabled
    @State private var audioOn = AppSettings.audioEnabled

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedNebulaBackground()
                VStack(spacing: 18) {
                    VStack(spacing: 14) {
                        Toggle(isOn: $hapticsOn) {
                            Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
                                .foregroundStyle(Palette.text)
                        }
                        .tint(Palette.accent)
                        .onChange(of: hapticsOn) { _, newValue in
                            AppSettings.hapticsEnabled = newValue
                            if newValue { Haptics.tap() }   // confirms it's back on
                        }

                        Divider().background(Palette.border)

                        Toggle(isOn: $audioOn) {
                            Label("Sound Effects", systemImage: "speaker.wave.2.fill")
                                .foregroundStyle(Palette.text)
                        }
                        .tint(Palette.accent)
                        .onChange(of: audioOn) { _, newValue in
                            AppSettings.audioEnabled = newValue
                            if newValue { ToneEngine.shared.play(frequency: 660, duration: 0.14, volume: 0.5) }
                        }
                    }
                    .padding(16)
                    .glassCard()

                    Text("Applies to word feedback, buttons, and sliders throughout the app.")
                        .font(GameFont.caption(11))
                        .foregroundStyle(Palette.dim)
                        .multilineTextAlignment(.center)

                    Spacer()
                }
                .padding(20)
                .padding(.top, 12)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
