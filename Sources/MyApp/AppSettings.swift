import SwiftUI

/// Persisted preferences. The booleans default to enabled (a missing
/// UserDefaults key must read as "on", so these use `object(forKey:)` rather
/// than the plain `bool(forKey:)` — which defaults missing keys to `false`
/// and would silently mute everyone on first launch).
enum AppSettings {
    private static let hapticsKey = "com.arnavaggarwal.shiritori.hapticsEnabled"
    private static let audioKey = "com.arnavaggarwal.shiritori.audioEnabled"
    private static let loggingKey = "com.arnavaggarwal.shiritori.gameLoggingEnabled"
    private static let lookupKey = "com.arnavaggarwal.shiritori.definitionLookupEnabled"

    static var hapticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hapticsKey) }
    }

    static var audioEnabled: Bool {
        get { UserDefaults.standard.object(forKey: audioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: audioKey) }
    }

    /// Whether finished games get written to the history log.
    static var gameLoggingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: loggingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: loggingKey) }
    }

    /// Shorter alias used at the single logging call site in `AppModel`.
    static var loggingEnabled: Bool { gameLoggingEnabled }

    /// Gates the one outbound internet call the app makes. The app otherwise
    /// talks to nothing but other devices on the local network, so this stays
    /// a preference rather than an assumption.
    static var definitionLookupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: lookupKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: lookupKey) }
    }
}

/// Settings screen — reachable from the gear on the home screen. Deliberately
/// not exposed mid-game: changing these while a round is running isn't a
/// scenario worth designing for.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var log = GameLogStore.shared

    @State private var hapticsOn = AppSettings.hapticsEnabled
    @State private var audioOn = AppSettings.audioEnabled
    @State private var loggingOn = AppSettings.gameLoggingEnabled
    @State private var lookupOn = AppSettings.definitionLookupEnabled
    @State private var showWipeWarning = false

    /// Which colour is being edited. A single enum-driven sheet rather than
    /// two `isPresented` sheets on the same view — SwiftUI only reliably
    /// honours one sheet per view, and the second would silently never open.
    private enum ColorTarget: Int, Identifiable {
        case accent, background
        var id: Int { rawValue }
    }
    @State private var editingColor: ColorTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedNebulaBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        feedbackSection
                        historySection
                        appearanceSection
                        Spacer(minLength: 20)
                    }
                    .padding(20)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingColor) { target in
                switch target {
                case .accent:
                    ColorEditorView(title: "Accent Colour",
                                    initial: theme.accentHex,
                                    defaultHex: ThemeStore.defaultAccent) { theme.setAccent($0) }
                case .background:
                    ColorEditorView(title: "Background Colour",
                                    initial: theme.bgHex,
                                    defaultHex: ThemeStore.defaultBg) { theme.setBackground($0) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: sections

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Feedback")
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

            caption("Applies to word feedback, buttons, and sliders throughout the app.")
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("History & Words")
            VStack(spacing: 14) {
                Toggle(isOn: $loggingOn) {
                    Label("Log completed games", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(Palette.text)
                }
                .tint(Palette.accent)
                .onChange(of: loggingOn) { _, newValue in
                    AppSettings.gameLoggingEnabled = newValue
                    Haptics.tap()
                }

                Divider().background(Palette.border)

                Toggle(isOn: $lookupOn) {
                    Label("Look up definitions online", systemImage: "book.closed.fill")
                        .foregroundStyle(Palette.text)
                }
                .tint(Palette.accent)
                .onChange(of: lookupOn) { _, newValue in
                    AppSettings.definitionLookupEnabled = newValue
                    Haptics.tap()
                }

                Divider().background(Palette.border)

                Button {
                    Haptics.tap()
                    showWipeWarning = true
                } label: {
                    HStack {
                        Label("Delete all game logs", systemImage: "trash.fill")
                            .foregroundStyle(log.count == 0 ? Palette.dim : Palette.redBright)
                        Spacer()
                        Text("\(log.count)")
                            .font(GameFont.caption(11))
                            .foregroundStyle(Palette.dim)
                    }
                }
                .buttonStyle(.plain)
                .disabled(log.count == 0)
            }
            .padding(16)
            .glassCard()

            caption("Looking up a word sends just that word to a third-party dictionary service. Everything else stays on your device.")
        }
        .alert("Delete all game logs?", isPresented: $showWipeWarning) {
            Button("Delete \(log.count) games", role: .destructive) {
                log.deleteAll()
                Haptics.rejected()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently erases every recorded game and the words played in them. It can't be undone. Your starred words are kept.")
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Appearance")
            VStack(spacing: 14) {
                colorRow(label: "Accent Colour", color: Palette.accent) { editingColor = .accent }
                Divider().background(Palette.border)
                colorRow(label: "Background Colour", color: Palette.bg) { editingColor = .background }

                if !theme.isDefault {
                    Divider().background(Palette.border)
                    Button {
                        Haptics.tap()
                        theme.resetToDefaults()
                    } label: {
                        HStack {
                            Label("Reset to nebula theme", systemImage: "arrow.uturn.backward")
                                .foregroundStyle(Palette.accent)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .glassCard()

            caption("The glow, borders and card fills are derived from these two, so the whole app follows along.")
        }
    }

    // MARK: bits

    private func colorRow(label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                Text(label)
                    .foregroundStyle(Palette.text)
                    .font(GameFont.body(15))
                Spacer()
                Circle()
                    .fill(color)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Palette.border, lineWidth: 1))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.dim)
            }
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(GameFont.caption(10))
            .foregroundStyle(Palette.dim)
            .tracking(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(GameFont.caption(11))
            .foregroundStyle(Palette.dim)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
