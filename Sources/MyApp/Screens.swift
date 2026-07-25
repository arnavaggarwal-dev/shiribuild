import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - Loading Screen

struct LoadingView: View {
    @EnvironmentObject var model: AppModel
    @State private var pulse = false
    @State private var showDiagnostic = false

    var body: some View {
        VStack(spacing: 18) {
            Text("✦").font(.system(size: 40)).foregroundStyle(Palette.accent)
                .scaleEffect(pulse ? 1.15 : 0.9)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            Text("SHIRITORI").font(GameFont.title(20)).foregroundStyle(Palette.text).tracking(4)
            BouncingDotsView()
            Text("loading the dictionary…").font(GameFont.caption()).foregroundStyle(Palette.dim)

            // After 3s, surface whatever the loader has recorded so far. If
            // the file can't be found or parsed, the reason shows here on
            // screen instead of the app hanging with no explanation.
            if showDiagnostic && !model.dict.diagnostic.isEmpty {
                Text(model.dict.diagnostic)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.top, 8)
                Button("Continue anyway") { Haptics.tap(); model.forceReady() }
                    .font(GameFont.caption()).foregroundStyle(Palette.accent).padding(.top, 4)
            }
        }
        .onAppear {
            pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showDiagnostic = true }
        }
    }
}

// MARK: - Lobby

struct LobbyView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNetworkAlert = false
    @State private var pendingNetworkAction: (() -> Void)?
    @State private var showSettings = false

    private func requireSameNetwork(then action: @escaping () -> Void) {
        pendingNetworkAction = action
        showNetworkAlert = true
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 4) {
                        Text("✦  SHIRITORI  ✦")
                            .font(GameFont.display(30))
                            .foregroundStyle(Palette.accent)
                            .glow(Palette.accent, radius: 18)
                        Text("chain words · survive · dominate")
                            .font(GameFont.caption())
                            .foregroundStyle(Palette.dim)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        Haptics.tap()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Palette.dim)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.border, lineWidth: 1))
                    }
                    .accessibilityLabel("Settings")
                }
                .padding(.top, 36)

                LobbyModeCard(
                    title: "Bot Mode", subtitle: "1-7 players + AI",
                    detail: "Play with friends on this device, plus an AI opponent with adjustable difficulty.",
                    icon: "cpu", accent: Palette.borderActive
                ) { model.route = .botSetup }

                LobbyModeCard(
                    title: "Local Play", subtitle: "2-8 players, same device",
                    detail: "Pass the phone or tablet around the table — everyone shares this screen.",
                    icon: "person.2.fill", accent: Palette.accent
                ) { model.route = .localSetup }

                LobbyModeCard(
                    title: "Host a Game", subtitle: "LAN · up to 8 players",
                    detail: "Start a game nearby players can discover and join automatically — no IP address needed.",
                    icon: "antenna.radiowaves.left.and.right", accent: Palette.glow
                ) { requireSameNetwork { model.route = .hostSetup } }

                LobbyModeCard(
                    title: "Join a Game", subtitle: "LAN",
                    detail: "Find a game already being hosted on this Wi-Fi network.",
                    icon: "wifi", accent: Palette.green
                ) { requireSameNetwork { model.startBrowsing() } }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 22)
        }
        .alert("Same Wi-Fi Required", isPresented: $showNetworkAlert) {
            Button("Got it") { pendingNetworkAction?(); pendingNetworkAction = nil }
            Button("Cancel", role: .cancel) { pendingNetworkAction = nil }
        } message: {
            Text("Everyone needs to be on the same Wi-Fi network to find each other — including if you're using a personal hotspot: every phone or PC playing must be connected to that same hotspot, not their own cellular data.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

private struct LobbyModeCard: View {
    var title: String
    var subtitle: String
    var detail: String
    var icon: String
    var accent: Color
    var action: () -> Void

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(GameFont.headline(16)).foregroundStyle(Palette.text)
                        Spacer()
                        Text(subtitle).font(GameFont.caption(10)).foregroundStyle(Palette.dim)
                    }
                    Text(detail).font(GameFont.body(12)).foregroundStyle(Palette.dim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.dim)
            }
            .padding(16)
            .glassCard(border: Palette.border)
        }
        .buttonStyle(PressableGlassButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Setup Screens

private func difficultyLabel(_ d: Int) -> String {
    switch d {
    case ...20: return "easy — short common words"
    case ...40: return "medium-easy"
    case ...60: return "medium"
    case ...80: return "hard — long/rare words"
    default: return "expert — maximum complexity"
    }
}

private func difficultyColor(_ d: Int) -> Color {
    switch d {
    case ...33: return Palette.green
    case ...66: return Palette.orange
    default: return Palette.redBright
    }
}

private struct SetupScaffold<Content: View>: View {
    var title: String
    var startTitle: String
    var startEnabled: Bool = true
    var onStart: () -> Void
    var onBack: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(title)
                    .font(GameFont.title(24))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 40)

                VStack(spacing: 22) { content }
                    .padding(20)
                    .glassCard()

                SolidButton(title: startTitle, isEnabled: startEnabled, action: onStart)
                GhostButton(title: "Back", systemImage: "chevron.left", action: onBack)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
    }
}

struct BotSetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SetupScaffold(
            title: "Bot Mode",
            startTitle: "Start Game",
            onStart: { model.startBotGame() },
            onBack: { model.route = .lobby }
        ) {
            LabeledSlider(label: "Human players", valueText: "\(Int(model.botHumanCount))",
                         value: $model.botHumanCount, range: 1...7, step: 1)
            Text("The bot always joins as an extra player.")
                .font(GameFont.caption()).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(Palette.border)

            LabeledSlider(label: "Bot difficulty", valueText: "\(Int(model.botDifficultyChoice))",
                         value: $model.botDifficultyChoice, range: 1...100, step: 1,
                         tint: difficultyColor(Int(model.botDifficultyChoice)))
            HStack {
                Text("1 Easy").foregroundStyle(Palette.green)
                Spacer()
                Text("50 Medium").foregroundStyle(Palette.orange)
                Spacer()
                Text("100 Expert").foregroundStyle(Palette.redBright)
            }
            .font(GameFont.caption(10))
            Text(difficultyLabel(Int(model.botDifficultyChoice)))
                .font(GameFont.caption(10)).foregroundStyle(Palette.dim)
        }
    }
}

struct LocalSetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SetupScaffold(
            title: "Local Game",
            startTitle: "Start Game",
            onStart: { model.startLocalGame() },
            onBack: { model.route = .lobby }
        ) {
            LabeledSlider(label: "Number of players", valueText: "\(Int(model.localPlayerCount))",
                         value: $model.localPlayerCount, range: 2...8, step: 1)
            Text("Pass the device to whoever's turn it is.")
                .font(GameFont.caption()).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HostSetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SetupScaffold(
            title: "Host a Game",
            startTitle: "Create Lobby",
            onStart: { model.createLobby() },
            onBack: { model.route = .lobby }
        ) {
            LabeledSlider(label: "Number of players", valueText: "\(Int(model.hostPlayerCount))",
                         value: $model.hostPlayerCount, range: 2...8, step: 1)
            Text("Nearby players will see your game appear automatically — nothing to type.")
                .font(GameFont.caption()).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Join

struct JoinListView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var browser: LANBrowser
    @State private var manualIP = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Join a Game").font(GameFont.title(24)).foregroundStyle(Palette.accent)
                    .padding(.top, 40)

                if browser.hosts.isEmpty {
                    VStack(spacing: 14) {
                        BouncingDotsView()
                        Text("Looking for nearby games…")
                            .font(GameFont.body(13)).foregroundStyle(Palette.dim)
                        Text("Make sure the host has created a lobby and you're on the same Wi-Fi.")
                            .font(GameFont.caption()).foregroundStyle(Palette.dim)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                    .glassCard()
                } else {
                    VStack(spacing: 10) {
                        ForEach(browser.hosts, id: \.self) { result in
                            Button {
                                Haptics.tap()
                                model.join(result)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(Palette.glow)
                                    Text(hostDisplayName(result))
                                        .font(GameFont.headline(14)).foregroundStyle(Palette.text)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.dim)
                                }
                                .padding(14)
                                .glassCard(border: Palette.borderActive)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Desktop (PC) hosts don't show up in the list above — they
                // don't broadcast Bonjour. Typing their IP reaches them on
                // the shared fixed port instead.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Join a PC game by IP")
                        .font(GameFont.headline(13)).foregroundStyle(Palette.text)
                    Text("Desktop hosts don't appear in the list — enter the IP shown on their screen.")
                        .font(GameFont.caption()).foregroundStyle(Palette.dim)
                    HStack(spacing: 10) {
                        TextField("192.168.1.42", text: $manualIP)
                            .font(GameFont.body(14)).foregroundStyle(Palette.text)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card2))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border, lineWidth: 1))
                        Button {
                            Haptics.tap()
                            model.joinManual(ip: manualIP)
                        } label: {
                            Text("Join")
                                .font(GameFont.headline(14)).foregroundStyle(Palette.text)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.borderActive))
                        }
                        .buttonStyle(.plain)
                        .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(manualIP.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    }
                }
                .padding(16)
                .glassCard()

                GhostButton(title: "Back", systemImage: "chevron.left") {
                    browser.stop()
                    model.route = .lobby
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Waiting Rooms

struct HostWaitingRoomView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var host: LANHost
    var total: Int

    /// The device's local IPv4 that other players can actually reach.
    /// Priority: en0 (Wi-Fi client) → bridge100 (this phone IS the hotspot;
    /// host is always 172.20.10.1 there) → any other private-LAN interface.
    /// Cellular (pdp_ip*), VPN (utun*/ipsec*), and Apple p2p (awdl0/llw0)
    /// interfaces are excluded: those addresses look valid but are
    /// unreachable by LAN peers, which sends PC players into a dead end.
    private var wifiIPv4: String? {
        var byName: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254") else { continue }
            byName[String(cString: ifa.ifa_name)] = ip
        }
        if let wifi = byName["en0"] { return wifi }
        if let hotspot = byName["bridge100"] { return hotspot }
        // Last resort: any remaining interface that isn't cellular/VPN/p2p.
        let unreachablePrefixes = ["pdp_ip", "utun", "ipsec", "awdl", "llw"]
        for (name, ip) in byName where !unreachablePrefixes.contains(where: { name.hasPrefix($0) }) {
            return ip
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 22) {
            Text("Lobby").font(GameFont.title(24)).foregroundStyle(Palette.accent)
            Text("Waiting for players…").font(GameFont.caption()).foregroundStyle(Palette.dim)

            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 26)).foregroundStyle(Palette.glow)
                Text("Broadcasting nearby").font(GameFont.caption(11)).foregroundStyle(Palette.dim)
                Text("\(host.connectedCount)/\(total) connected")
                    .font(GameFont.mono(24)).foregroundStyle(Palette.accent)
            }
            .padding(28)
            .glassCard()

            // Desktop players can't see the Bonjour broadcast — they type
            // this into their PC client to join.
            VStack(spacing: 6) {
                Text("PC players join with").font(GameFont.caption(11)).foregroundStyle(Palette.dim)
                if let ip = wifiIPv4 {
                    Text(ip).font(GameFont.mono(20)).foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                } else {
                    Text("No Wi-Fi address found — check Wi-Fi is on")
                        .font(GameFont.caption()).foregroundStyle(Palette.redBright)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .glassCard()

            if let err = host.startError {
                Text(err).font(GameFont.caption()).foregroundStyle(Palette.redBright)
                    .multilineTextAlignment(.center)
            } else {
                BouncingDotsView()
                Text("Game starts automatically once everyone's in.")
                    .font(GameFont.caption()).foregroundStyle(Palette.dim)
            }

            GhostButton(title: "Cancel", systemImage: "xmark") { model.backToLobby() }
        }
        .padding(.horizontal, 30)
        .onChange(of: host.gameStarted) { _, started in
            if started { model.route = .hostGame }
        }
    }
}

struct ClientWaitingRoomView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: LANClient

    var body: some View {
        VStack(spacing: 22) {
            Text("Lobby").font(GameFont.title(24)).foregroundStyle(Palette.accent)
            VStack(spacing: 10) {
                BouncingDotsView()
                Text(client.connectedWaitingText)
                    .font(GameFont.headline(14)).foregroundStyle(Palette.glow)
            }
            .padding(28)
            .glassCard()
            Text("Game starts when all players join.").font(GameFont.caption()).foregroundStyle(Palette.dim)
            GhostButton(title: "Cancel", systemImage: "xmark") { model.backToLobby() }
        }
        .padding(.horizontal, 30)
        .onChange(of: client.gameStarted) { _, started in
            if started { model.route = .clientGame }
        }
        .onChange(of: client.didDisconnect) { _, disconnected in
            if disconnected { model.route = .disconnected }
        }
    }
}

// MARK: - Disconnected

struct DisconnectedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("✦").font(.system(size: 40)).foregroundStyle(Palette.red)
            Text("Disconnected").font(GameFont.title(20)).foregroundStyle(Palette.redBright)
            Text("Connection to the host was lost.")
                .font(GameFont.body(13)).foregroundStyle(Palette.dim)
            SolidButton(title: "Back to Lobby", action: { model.backToLobby() })
                .padding(.top, 10)
        }
        .padding(30)
        .glassCard()
        .padding(.horizontal, 40)
    }
}

// MARK: - Shared Game UI Pieces

/// Brief full-screen tint on accept/reject so a move reads instantly even
/// out of the corner of your eye — pairs with the screen shake on rejects.
private struct GameEventFlash: ViewModifier {
    var event: GameEvent
    @State private var flashColor = Color.clear
    @State private var flashOpacity = 0.0

    func body(content: Content) -> some View {
        content
            .overlay(flashColor.opacity(flashOpacity).allowsHitTesting(false).ignoresSafeArea())
            .onChange(of: event) { _, new in
                let color: Color?
                switch new {
                case .accepted, .botPlayed: color = Palette.green
                case .rejected, .eliminated: color = Palette.redBright
                default: color = nil
                }
                guard let color else { return }
                flashColor = color
                withAnimation(.easeOut(duration: 0.12)) { flashOpacity = 0.16 }
                withAnimation(.easeOut(duration: 0.5).delay(0.12)) { flashOpacity = 0 }
            }
    }
}

extension View {
    func gameEventFlash(_ event: GameEvent) -> some View { modifier(GameEventFlash(event: event)) }
}

struct GameHeaderCard: View {
    var currentWord: String
    var turnLabel: String
    var isBotThinking: Bool
    var forbiddenLetter: String
    var timeLeft: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if isBotThinking {
                        HStack(spacing: 6) {
                            Text("🤖 Bot is thinking").font(GameFont.caption()).foregroundStyle(Palette.dim)
                            BouncingDotsView()
                        }
                    } else {
                        Text(turnLabel).font(GameFont.caption()).foregroundStyle(Palette.dim)
                    }
                    Text(currentWord)
                        .font(GameFont.display(32))
                        .foregroundStyle(Palette.glow)
                        .glow(Palette.glow, radius: 12, opacity: 0.35)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Current word: \(currentWord)")
                }
                Spacer()
                HStack(spacing: 8) {
                    CircularTimerView(timeLeft: timeLeft)
                    VStack(spacing: 2) {
                        Text("forbidden").font(GameFont.caption(9)).foregroundStyle(Palette.red)
                        Text(forbiddenLetter.uppercased())
                            .font(GameFont.mono(20)).foregroundStyle(Palette.red)
                    }
                    .frame(width: 52, height: 52)
                    .glassCard(border: Palette.forbiddenBorder, fill: Palette.card2, radius: 12)
                }
            }
            if let last = currentWord.last {
                Text("Next word must start with \u{201C}\(String(last))\u{201D}")
                    .font(GameFont.caption()).foregroundStyle(Palette.dim)
            }
        }
        .padding(16)
        .glassCard()
    }
}

struct InputCard: View {
    @Binding var text: String
    var isEnabled: Bool
    var message: String
    var messageColor: Color
    var onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextField("Type your word…", text: $text)
                .font(GameFont.body(15))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Palette.card2)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .accessibilityLabel("Word input")
                .accessibilityHint(isEnabled ? "Type a word and submit" : "Not your turn")

            SolidButton(title: "Play Word", systemImage: "arrow.up.circle.fill",
                       isEnabled: isEnabled && !text.trimmingCharacters(in: .whitespaces).isEmpty,
                       action: onSubmit)

            if !message.isEmpty {
                Text(message)
                    .font(GameFont.caption(11))
                    .foregroundStyle(messageColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: message)
            }
        }
        .padding(14)
        .glassCard()
    }
}

struct ChainCard: View {
    var words: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Word chain").font(GameFont.caption()).foregroundStyle(Palette.dim)
                Spacer()
                Text("\(words.count)").font(GameFont.headline(12)).foregroundStyle(Palette.accent)
            }
            WordChainView(words: words)
        }
        .padding(14)
        .glassCard()
    }
}

struct ScoreStrip: View {
    var numPlayers: Int
    var scores: [Int]
    var activePlayers: [Int]
    var currentPlayer: Int
    var botPlayerNum: Int?
    var myPlayerNum: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1...max(numPlayers, 1), id: \.self) { p in
                    ScoreCardView(
                        playerNum: p,
                        isBot: p == botPlayerNum,
                        score: p - 1 < scores.count ? scores[p - 1] : 0,
                        isActive: p == currentPlayer && activePlayers.contains(p),
                        isOut: !activePlayers.contains(p),
                        isMe: p == myPlayerNum
                    )
                    .frame(width: 148)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct DifficultyLiveCard: View {
    @Binding var difficulty: Double
    var dangerPoolPercent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🤖 Difficulty").font(GameFont.caption()).foregroundStyle(Palette.glow)
                Spacer()
                Text("\(Int(difficulty))").font(GameFont.headline(12)).foregroundStyle(Palette.glow)
            }
            Slider(value: $difficulty, in: 1...100, step: 1)
                .tint(difficultyColor(Int(difficulty)))
                .onChange(of: difficulty) { _, newValue in
                    Haptics.sliderTick(fraction: (newValue - 1) / 99)
                }
            Text(difficultyLabel(Int(difficulty))).font(GameFont.caption(10)).foregroundStyle(Palette.dim)
            Text("Danger pool: \(dangerPoolPercent)%").font(GameFont.caption(10)).foregroundStyle(Palette.dim)
        }
        .padding(14)
        .glassCard()
    }
}

struct NotepadCard: View {
    @EnvironmentObject var model: AppModel
    @State private var words: [String] = []
    @State private var entry = ""
    @State private var note = ""
    @State private var noteColor = Palette.dim
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notepad").font(GameFont.caption()).foregroundStyle(Palette.text)
                Spacer()
                Text("jot words").font(GameFont.caption(9)).foregroundStyle(Palette.dim)
            }
            if !words.isEmpty {
                ScrollView {
                    Text(words.joined(separator: "\n"))
                        .font(GameFont.body(12)).foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 70)
                .padding(8)
                .background(Palette.card2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                TextField("word → save", text: $entry)
                    .font(GameFont.body(13))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Palette.card2)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .onSubmit(save)
                Button(action: { Haptics.tap(); save() }) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Palette.accent)
                        .font(.system(size: 22))
                }
            }
            if !note.isEmpty {
                Text(note).font(GameFont.caption(10)).foregroundStyle(noteColor)
            }
        }
        .padding(14)
        .glassCard()
    }

    private func save() {
        let raw = entry.trimmingCharacters(in: .whitespaces).lowercased()
        entry = ""
        guard !raw.isEmpty else { focused = true; return }
        if !model.dict.isValid(raw) {
            note = "\"\(raw)\" — not a word"; noteColor = Palette.red
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { note = "" }
            focused = true; return
        }
        words.append(raw)
        note = "\"\(raw)\" saved ✓"; noteColor = Palette.green
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { note = "" }
        focused = true
    }
}

struct CommandsCard: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("commands").font(GameFont.caption(9)).foregroundStyle(Palette.dim)
            ForEach(["/skip", "/donate <pts> <p>", "/wordlist", "/help"], id: \.self) { cmd in
                Text(cmd).font(GameFont.caption(10)).foregroundStyle(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .glassCard()
    }
}

// MARK: - Game Screen (bot / local / LAN host)

/// Small "leave the game" control shown at the top of every in-game screen.
/// Confirms first, since backToLobby() abandons the current game (and, for a
/// host, tears down the LAN lobby for everyone).
struct QuitButton: View {
    var isClient: Bool = false
    var onQuit: () -> Void
    @State private var showConfirm = false

    var body: some View {
        Button {
            Haptics.tap()
            showConfirm = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                Text("Leave")
            }
            .font(GameFont.headline(13))
            .foregroundStyle(Palette.dim)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
        }
        .accessibilityLabel("Leave game")
        .confirmationDialog("Leave this game?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Leave game", role: .destructive) { Haptics.tap(); onQuit() }
            Button("Keep playing", role: .cancel) { }
        } message: {
            Text(isClient
                 ? "You'll disconnect and return to the lobby."
                 : "This ends the current game and returns to the lobby.")
        }
    }
}

struct GameView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: GameEngine
    var myPlayerNum: Int?
    @State private var text = ""

    private var inputEnabled: Bool {
        engine.state.currentPlayer != engine.botPlayerNum &&
        (myPlayerNum == nil || engine.state.currentPlayer == myPlayerNum)
    }

    private var turnLabel: String {
        if let myPlayerNum, engine.state.currentPlayer == myPlayerNum { return "✦ Your turn!" }
        return "Player \(engine.state.currentPlayer)'s turn"
    }

    private var difficultyBinding: Binding<Double> {
        Binding(get: { Double(engine.botDifficulty) }, set: { engine.botDifficulty = Int($0) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    QuitButton { model.backToLobby() }
                    Spacer()
                }

                GameHeaderCard(currentWord: engine.state.previousWord, turnLabel: turnLabel,
                              isBotThinking: engine.isBotThinking, forbiddenLetter: engine.state.forbidden,
                              timeLeft: engine.timeLeft)

                InputCard(text: $text, isEnabled: inputEnabled, message: engine.message,
                         messageColor: engine.messageColor, onSubmit: submit)

                ChainCard(words: engine.state.wordList)

                ScoreStrip(numPlayers: engine.state.numPlayers, scores: engine.state.scores,
                          activePlayers: engine.state.activePlayers, currentPlayer: engine.state.currentPlayer,
                          botPlayerNum: engine.botPlayerNum, myPlayerNum: myPlayerNum)

                if engine.botPlayerNum != nil {
                    DifficultyLiveCard(difficulty: difficultyBinding, dangerPoolPercent: engine.dangerPoolPercent)
                }

                NotepadCard()
                CommandsCard()
            }
            .frame(maxWidth: 640)
            .padding(16)
        }
        .shake(engine.shakeTrigger)
        .gameEventFlash(engine.lastEvent)
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        let raw = text
        text = ""
        engine.attemptAction(playerNum: engine.state.currentPlayer, raw: raw)
    }
}

enum EngineGameMode { case bot, local, host }

struct EngineGameScreen: View {
    @EnvironmentObject var model: AppModel
    var mode: EngineGameMode

    var body: some View {
        switch mode {
        case .bot:
            if let e = model.engine { GameView(engine: e, myPlayerNum: nil) }
        case .local:
            if let e = model.engine { GameView(engine: e, myPlayerNum: nil) }
        case .host:
            if let h = model.lanHost { GameView(engine: h.engine, myPlayerNum: 1) }
        }
    }
}

// MARK: - Game Screen (LAN client)

struct ClientGameScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let client = model.lanClient {
            ClientGameView(client: client)
        }
    }
}

struct ClientGameView: View {
    @ObservedObject var client: LANClient
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    private var inputEnabled: Bool {
        client.myPlayerNum != nil && client.state.currentPlayer == client.myPlayerNum
    }

    private var turnLabel: String {
        inputEnabled ? "✦ Your turn!" : "Player \(client.state.currentPlayer)'s turn"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    QuitButton(isClient: true) { model.backToLobby() }
                    Spacer()
                }

                GameHeaderCard(currentWord: client.state.previousWord, turnLabel: turnLabel,
                              isBotThinking: false, forbiddenLetter: client.state.forbidden,
                              timeLeft: client.timeLeft)

                InputCard(text: $text, isEnabled: inputEnabled, message: client.message,
                         messageColor: client.messageColor, onSubmit: submit)

                ChainCard(words: client.state.wordList)

                ScoreStrip(numPlayers: client.state.numPlayers, scores: client.state.scores,
                          activePlayers: client.state.activePlayers, currentPlayer: client.state.currentPlayer,
                          botPlayerNum: nil, myPlayerNum: client.myPlayerNum)

                NotepadCard()
                CommandsCard()
            }
            .frame(maxWidth: 640)
            .padding(16)
        }
        .shake(client.shakeTrigger)
        .gameEventFlash(client.lastEvent)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: client.isGameOver) { _, over in
            if over { model.clientGameEnded() }
        }
        .onChange(of: client.didDisconnect) { _, disconnected in
            if disconnected { model.route = .disconnected }
        }
    }

    private func submit() {
        let raw = text
        text = ""
        client.submitCommandOrWord(raw)
    }
}

// MARK: - Winner Screen

struct WinnerView: View {
    @EnvironmentObject var model: AppModel
    var info: WinnerInfo
    @State private var appear = false

    private var winnerIsMe: Bool { info.myPlayerNum != nil && info.myPlayerNum == info.winner }

    var body: some View {
        ZStack {
            ConfettiView()
            ScrollView {
                VStack(spacing: 18) {
                    Text("✦")
                        .font(.system(size: 46))
                        .foregroundStyle(info.isBot ? Palette.glow : Palette.accent)
                        .scaleEffect(appear ? 1 : 0.4)
                        .padding(.top, 40)
                    Text("Game Over").font(GameFont.title(24)).foregroundStyle(Palette.text)
                    Text(winnerText)
                        .font(GameFont.headline(16))
                        .foregroundStyle(info.isBot ? Palette.glow : (winnerIsMe ? Palette.glow : Palette.accent))
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Final Scores").font(GameFont.caption()).foregroundStyle(Palette.dim)
                        ForEach(sortedPlayers, id: \.self) { p in
                            HStack {
                                Text(rowLabel(p))
                                    .font(GameFont.body(13))
                                    .fontWeight(p == info.winner ? .bold : .regular)
                                Spacer()
                                Text("\(safeScore(p)) pts").font(GameFont.mono(14))
                            }
                            .foregroundStyle(rowColor(p))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Palette.card2)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        HStack(spacing: 4) {
                            Text("Words played: \(info.wordsPlayed)")
                            if let d = info.botDifficulty { Text("· Bot difficulty: \(d)/100") }
                        }
                        .font(GameFont.caption(10)).foregroundStyle(Palette.dim)
                    }
                    .padding(16)
                    .glassCard()

                    SolidButton(title: "Play Again", systemImage: "arrow.counterclockwise") {
                        model.backToLobby()
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { appear = true }
        }
    }

    private var winnerText: String {
        let base = info.isBot ? "🤖 Bot wins!" : "\(info.names(info.winner)) wins!"
        return winnerIsMe ? "\(base) That's you!" : base
    }

    private var sortedPlayers: [Int] {
        Array(1...max(info.numPlayers, 1)).sorted { safeScore($0) > safeScore($1) }
    }

    private func safeScore(_ p: Int) -> Int { p - 1 < info.scores.count ? info.scores[p - 1] : 0 }

    private func rowLabel(_ p: Int) -> String {
        var label = info.names(p)
        if p == info.myPlayerNum { label += " (you)" }
        if !info.active.contains(p) { label += " · out" }
        if p == info.winner { label += " 🏆" }
        return label
    }

    private func rowColor(_ p: Int) -> Color {
        if p == info.winner { return info.isBot ? Palette.glow : Palette.accent }
        if !info.active.contains(p) { return Palette.redBright }
        return Palette.dim
    }
}

