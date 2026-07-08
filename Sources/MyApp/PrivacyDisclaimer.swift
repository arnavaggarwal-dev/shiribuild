import SwiftUI

/// A one-time "before you play" disclaimer. Shown exactly once, ever, on
/// first launch, then never again — gated by a UserDefaults flag rather
/// than literal file deletion. (Deleting a bundled resource at runtime
/// isn't really a thing on iOS — the .app bundle is read-only, and even if
/// it were writable, a reinstall would restore it. UserDefaults persists
/// across launches without persisting across reinstalls, which is exactly
/// "show once per install" — the practical equivalent of what was asked.)
enum PrivacyDisclaimer {
    private static let seenKey = "com.arnavaggarwal.shiritori.hasSeenPrivacyDisclaimer.v1"

    static var hasBeenSeen: Bool {
        UserDefaults.standard.bool(forKey: seenKey)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }
}

struct PrivacyDisclaimerView: View {
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 22) {
                Text("✦").font(.system(size: 36)).foregroundStyle(Palette.accent)
                Text("Before You Play").font(GameFont.title(22)).foregroundStyle(Palette.text)

                VStack(alignment: .leading, spacing: 14) {
                    disclaimerRow(icon: "server.rack",
                        text: "There is no server. This app has no backend, no account system, and nothing you do here is sent to us — because there's no \"us\" to send it to.")
                    disclaimerRow(icon: "wifi",
                        text: "Multiplayer works by connecting directly, phone-to-phone or phone-to-PC, over your local Wi-Fi network. That connection never leaves your network.")
                    disclaimerRow(icon: "eye.slash",
                        text: "No analytics, no tracking, no ads. Nothing is collected — there's simply nowhere for it to go.")
                }
                .padding(20)
                .glassCard()

                Text("This message is shown once and won't appear again.")
                    .font(GameFont.caption(11)).foregroundStyle(Palette.dim)

                SolidButton(title: "Got it", action: {
                    Haptics.tap()
                    PrivacyDisclaimer.markSeen()
                    withAnimation(.easeOut(duration: 0.25)) { onDismiss() }
                })
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 440)
        }
        .transition(.opacity)
    }

    private func disclaimerRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Palette.glow)
                .frame(width: 22)
            Text(text)
                .font(GameFont.body(13))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
