import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - App Coordinator

/// Single source of truth for which screen is showing and which game
/// backend (bot / local / LAN host / LAN client) is currently live.
final class AppModel: ObservableObject {
    @Published var route: Route = .lobby

    // setup screen selections, kept as Double for direct Slider binding
    @Published var botHumanCount: Double = 1
    @Published var botDifficultyChoice: Double = 50
    @Published var localPlayerCount: Double = 2
    @Published var hostPlayerCount: Double = 2

    let dict = DictionaryStore()
    let browser = LANBrowser()

    private var cancellables = Set<AnyCancellable>()

    init() {
        // SwiftUI does NOT observe nested ObservableObjects: RootView watches
        // AppModel, but dict is its own ObservableObject, so dict.isLoaded
        // flipping never triggered a re-render — the loading screen sat there
        // forever even though the dictionary had loaded fine. Forward the
        // child's change signal through the parent.
        dict.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    @Published var engine: GameEngine?
    @Published var lanHost: LANHost?
    @Published var lanClient: LANClient?

    func loadDictionary() { dict.load() }
    func forceReady() { dict.markReadyUnvalidated() }

    func backToLobby() {
        engine?.stop()
        lanHost?.stopHosting()
        lanClient?.disconnect()
        browser.stop()
        engine = nil; lanHost = nil; lanClient = nil
        route = .lobby
    }

    /// Called when the app backgrounds. If we're actively hosting a LAN
    /// game, tear it down right now — proactively, while still foreground —
    /// rather than letting the OS suspend us mid-session. Without this, the
    /// connection eventually gets discovered dead only when the app is
    /// reopened, and by then forceRemove sees the host as the sole
    /// remaining player and spuriously declares them the winner for having
    /// left. Ending it here (no winner, just back to lobby) is honest about
    /// what actually happened: the host walked away.
    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .background, lanHost != nil else { return }
        switch route {
        case .waitingHost, .hostGame:
            backToLobby()
        default:
            break
        }
    }

    // MARK: bot mode

    func startBotGame() {
        let n = Int(botHumanCount) + 1
        let e = GameEngine(dict: dict, numPlayers: n, botPlayerNum: n, botDifficulty: Int(botDifficultyChoice))
        e.onGameOver = { [weak self, weak e] winner, note in
            guard let self, let e else { return }
            self.showWinner(from: e.state, winner: winner, botNum: n, botDifficulty: e.botDifficulty,
                            note: note, myPlayerNum: nil)
        }
        engine = e
        route = .botGame
        e.start()
    }

    // MARK: local pass-and-play

    func startLocalGame() {
        let n = Int(localPlayerCount)
        let e = GameEngine(dict: dict, numPlayers: n, botPlayerNum: nil)
        e.onGameOver = { [weak self, weak e] winner, note in
            guard let self, let e else { return }
            self.showWinner(from: e.state, winner: winner, botNum: nil, botDifficulty: nil,
                            note: note, myPlayerNum: nil)
        }
        engine = e
        route = .localGame
        e.start()
    }

    // MARK: LAN host

    func createLobby() {
        let n = Int(hostPlayerCount)
        let host = LANHost(numPlayers: n, dict: dict)
        host.onGameEnded = { [weak self, weak host] winner, note in
            guard let self, let host else { return }
            self.showWinner(from: host.engine.state, winner: winner, botNum: nil, botDifficulty: nil,
                            note: note, myPlayerNum: 1)
        }
        host.startHosting(deviceName: UIDevice.current.name)
        lanHost = host
        route = .waitingHost(total: n)
    }

    // MARK: LAN join

    func startBrowsing() {
        browser.start()
        route = .joinList
    }

    func join(_ result: NWBrowser.Result) {
        let client = LANClient()
        client.connect(to: result.endpoint)
        lanClient = client
        route = .waitingClient
    }

    /// Joins a desktop (Python) host by typed IP — those hosts don't
    /// advertise over Bonjour, they just listen on the fixed port 55731.
    func joinManual(ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let client = LANClient()
        client.connect(to: .hostPort(host: NWEndpoint.Host(trimmed),
                                     port: NWEndpoint.Port(rawValue: 55731)!))
        lanClient = client
        route = .waitingClient
    }

    func clientGameEnded() {
        guard let c = lanClient else { return }
        showWinner(from: c.state, winner: c.winner ?? 0, botNum: nil, botDifficulty: nil,
                  note: c.message, myPlayerNum: c.myPlayerNum)
    }

    // MARK: winner screen assembly

    private func showWinner(from state: GameState, winner: Int, botNum: Int?, botDifficulty: Int?,
                             note: String, myPlayerNum: Int?) {
        let info = WinnerInfo(
            winner: winner,
            isBot: botNum != nil && winner == botNum,
            scores: state.scores,
            active: state.activePlayers,
            numPlayers: state.numPlayers,
            wordsPlayed: state.wordList.count,
            botDifficulty: botDifficulty,
            myPlayerNum: myPlayerNum,
            names: { p in (botNum != nil && p == botNum) ? "🤖 Bot" : "Player \(p)" },
            extraNote: note
        )
        route = .winner(info)
    }
}

