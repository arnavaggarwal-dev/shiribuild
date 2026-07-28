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
    /// Merged Bot+Local setup: humans and bots share one 8-player cap.
    /// Humans floors at 1 (enforced by the setup view's slider binding, not
    /// here); bots floors at 0, which is what makes this screen also cover
    /// what used to be pure Local Play.
    @Published var playHumanCount: Double = 2
    @Published var playBotCount: Double = 0
    @Published var botDifficultyChoice: Double = 50
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

    // MARK: merged bot + local play

    /// Total players across both sliders, for the setup screen's Start-button
    /// gate (a 1-player game would crash `GameEngine.eliminate` — see
    /// `PlaySetupView`).
    var playTotalCount: Int { Int(playHumanCount) + Int(playBotCount) }

    func startGame() {
        let humans = Int(playHumanCount)
        let bots = Int(playBotCount)
        let n = humans + bots
        // Bot seats are the last `bots` seats, humans take the rest.
        let botSeats: Set<Int> = bots > 0 ? Set((humans + 1)...(humans + bots)) : []
        let e = GameEngine(dict: dict, numPlayers: n, botPlayerNums: botSeats,
                           botDifficulty: Int(botDifficultyChoice))
        e.onGameOver = { [weak self, weak e] winner, note in
            guard let self, let e else { return }
            self.showWinner(from: e.state, winner: winner, botPlayerNums: botSeats,
                            botDifficulty: bots > 0 ? e.botDifficulty : nil,
                            note: note, myPlayerNum: nil, mode: bots > 0 ? .bot : .local)
        }
        engine = e
        route = .playGame
        e.start()
    }

    // MARK: LAN host

    func createLobby() {
        let n = Int(hostPlayerCount)
        let host = LANHost(numPlayers: n, dict: dict)
        host.onGameEnded = { [weak self, weak host] winner, note in
            guard let self, let host else { return }
            self.showWinner(from: host.engine.state, winner: winner, botPlayerNums: [], botDifficulty: nil,
                            note: note, myPlayerNum: 1, mode: .host)
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
        showWinner(from: c.state, winner: c.winner ?? 0, botPlayerNums: [], botDifficulty: nil,
                  note: c.message, myPlayerNum: c.myPlayerNum, mode: .client)
    }

    // MARK: winner screen assembly

    /// Every finished game — bot, local, hosted and joined alike — funnels
    /// through here, which makes it the one place the history log needs to
    /// hook. `mode` is passed in explicitly rather than inferred from
    /// `botPlayerNums`/`myPlayerNum`, since those can't distinguish a local
    /// pass-and-play game from a joined LAN one.
    private func showWinner(from state: GameState, winner: Int, botPlayerNums: Set<Int>, botDifficulty: Int?,
                             note: String, myPlayerNum: Int?, mode: GameMode) {
        if AppSettings.loggingEnabled {
            GameLogStore.shared.record(GameLogEntry(
                date: Date(),
                mode: mode,
                numPlayers: state.numPlayers,
                winner: winner,
                winnerWasBot: botPlayerNums.contains(winner),
                myPlayerNum: myPlayerNum,
                scores: state.scores,
                words: state.wordList,
                botDifficulty: botDifficulty,
                note: note
            ))
        }

        let info = WinnerInfo(
            winner: winner,
            isBot: botPlayerNums.contains(winner),
            scores: state.scores,
            active: state.activePlayers,
            numPlayers: state.numPlayers,
            wordsPlayed: state.wordList.count,
            botDifficulty: botDifficulty,
            myPlayerNum: myPlayerNum,
            names: { p in botPlayerNums.contains(p) ? "🤖 Bot" : "Player \(p)" },
            extraNote: note
        )
        route = .winner(info)
    }
}

