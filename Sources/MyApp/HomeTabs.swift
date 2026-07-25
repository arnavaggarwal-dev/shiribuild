import SwiftUI

// MARK: - Tabs

/// The six home tabs: the four ways to start a game, plus the history log and
/// the starred-word collection.
enum HomeTab: String, CaseIterable, Identifiable {
    case bot, local, host, join, logs, starred

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bot: return "Bot"
        case .local: return "Local"
        case .host: return "Host"
        case .join: return "Join"
        case .logs: return "Logs"
        case .starred: return "Starred"
        }
    }

    var icon: String {
        switch self {
        case .bot: return "cpu"
        case .local: return "person.2.fill"
        case .host: return "antenna.radiowaves.left.and.right"
        case .join: return "wifi"
        case .logs: return "clock.arrow.circlepath"
        case .starred: return "star.fill"
        }
    }

    var needsLocalNetwork: Bool { self == .host || self == .join }
}

// MARK: - Home

/// Replaces the old single lobby screen. Deliberately a hand-rolled tab bar
/// rather than a `TabView`: SwiftUI caps a `TabView` at five visible tabs on
/// iPhone and shunts the rest into a system "More" list, which would bury
/// Logs and Starred behind unstyled chrome. The app already hand-rolls all of
/// its navigation, so a custom bar is the consistent choice too.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch model.homeTab {
                case .bot: BotSetupView()
                case .local: LocalSetupView()
                case .host: HostSetupView()
                case .join:
                    JoinListView(browser: model.browser)
                        .onAppear { model.startBrowsing() }
                        .onDisappear { model.stopBrowsing() }
                case .logs: GameLogView()
                case .starred: StarredView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HomeTabBar(selection: $model.homeTab)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var header: some View {
        ZStack {
            Text("✦  SHIRITORI  ✦")
                .font(GameFont.headline(15))
                .foregroundStyle(Palette.accent)
                .glow(Palette.accent, radius: 12)

            HStack {
                Spacer()
                Button {
                    Haptics.tap()
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.dim)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.border, lineWidth: 1))
                }
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Tab bar

private struct HomeTabBar: View {
    @Binding var selection: HomeTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases) { tab in
                Button {
                    guard selection != tab else { return }
                    Haptics.tap()
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(tab.label)
                            .font(GameFont.caption(9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selection == tab ? Palette.accent : Palette.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }
}

// MARK: - Shared bits

/// The old lobby gated Host/Join behind a modal "Same Wi-Fi Required" alert.
/// As tabs there's no navigation moment left to gate, so the same guidance
/// shows inline at the top of both networked tabs instead.
struct WiFiNoticeCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.orange)
            Text("Everyone must be on the same Wi-Fi — including on a personal hotspot, where every device has to join that hotspot rather than use its own cellular data.")
                .font(GameFont.caption(11))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassCard(border: Palette.border)
    }
}

/// Shared "nothing here yet" panel for the Logs and Starred tabs.
struct EmptyStateCard: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.dim)
            Text(title)
                .font(GameFont.headline(15))
                .foregroundStyle(Palette.text)
            Text(message)
                .font(GameFont.body(12))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassCard()
    }
}
