import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - Wire Framing

/// Length-prefixed JSON over TCP — a 4-byte big-endian size header followed
/// by that many bytes of payload. Same idea as `send_msg`/`recv_msg` in
/// shiritori_net.py, just written by hand instead of relying on an
/// NWProtocolFramer subclass.
enum WireFraming {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        guard let payload = try? JSONEncoder().encode(value) else { return nil }
        let n = UInt32(payload.count)
        let header = Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        return header + payload
    }

    private static func decodeLength(_ header: Data) -> Int {
        let b = [UInt8](header)
        guard b.count == 4 else { return 0 }
        return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
    }

    static func receiveLoop(_ connection: NWConnection,
                             onMessage: @escaping (Data) -> Void,
                             onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard let header, header.count == 4, error == nil else { onClose(); return }
            let length = decodeLength(header)
            guard length > 0, length < 10_000_000 else { onClose(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error2 in
                guard let body, body.count == length, error2 == nil else { onClose(); return }
                onMessage(body)
                receiveLoop(connection, onMessage: onMessage, onClose: onClose)
            }
        }
    }

    static func send(_ msg: NetMessage, on connection: NWConnection) {
        guard let data = encode(msg) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

// MARK: - LAN Host

/// Runs the authoritative GameEngine and advertises it over Bonjour. The
/// host device plays as Player 1 directly against `engine` (no loopback
/// connection needed, unlike the Python version) — remote players connect
/// in as players 2...N and their moves arrive as `.action` messages.
final class LANHost: ObservableObject {
    @Published var connectedCount = 1     // host itself counts as seat 1
    @Published var startError: String?
    @Published var gameStarted = false

    let numPlayers: Int
    let engine: GameEngine
    /// Fires once after the engine reports game over — after LANHost has
    /// already broadcast the game_end packet to every client.
    var onGameEnded: ((Int, String) -> Void)?
    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]
    private var nextPlayerSlot = 2
    private var remoteJoined = 0
    /// Set before intentionally cancelling connections (stopHosting, or the
    /// host backgrounding the app). NWConnection.cancel() delivers its
    /// .cancelled state update asynchronously — without this guard, that
    /// delayed callback reaches handleDisconnect AFTER teardown started,
    /// forceRemove sees the host as the sole remaining active player, and
    /// spuriously declares the host the winner for leaving the game.
    private var isShuttingDown = false

    init(numPlayers: Int, dict: DictionaryStore) {
        self.numPlayers = numPlayers
        // The host plays seat 1 on this device; seats 2...N are remote.
        self.engine = GameEngine(dict: dict, numPlayers: numPlayers, botPlayerNum: nil,
                                 localPlayerNum: 1)
        engine.onStateChanged = { [weak self] state, text, color in
            self?.broadcast(.stateEnvelope(.stateUpdate, state: state, text: text, color: color))
        }
        engine.onGameOver = { [weak self] winner, note in
            guard let self else { return }
            self.broadcast(.stateEnvelope(.gameEnd, state: self.engine.state, text: note, winner: winner))
            self.onGameEnded?(winner, note)
        }
        // Relay the authoritative per-second clock so client countdowns move.
        engine.onTick = { [weak self] timeLeft in
            self?.broadcast(NetMessage(type: .tick, timeLeft: timeLeft))
        }
        // Relay a rejected move to just the player who made it. Seat 1 is the
        // host and has no entry in `connections`, so a host reject no-ops here
        // and is shown locally by the engine instead.
        engine.onReject = { [weak self] player, text in
            self?.sendToPlayer(player, NetMessage(type: .msg, text: text))
        }
    }

    func startHosting(deviceName: String) {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            // Fixed port 55731 = PORT in shiritori_net.py, so desktop players
            // can join with just this device's IP. Bonjour advertisement on
            // top keeps iOS↔iOS discovery automatic.
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: 55731)!)
            l.service = NWListener.Service(name: "\(deviceName)'s Shiritori", type: "_shiritori._tcp")
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: .main)
            listener = l
        } catch {
            startError = "Couldn't start hosting: \(error.localizedDescription)"
        }
    }

    private func accept(_ connection: NWConnection) {
        guard nextPlayerSlot <= numPlayers else { connection.cancel(); return }
        let slot = nextPlayerSlot
        nextPlayerSlot += 1
        remoteJoined += 1
        connections[slot] = connection
        connectedCount = remoteJoined + 1

        connection.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.handleDisconnect(slot)
            default: break
            }
        }
        connection.start(queue: .main)
        WireFraming.send(NetMessage(type: .welcome, playerNum: slot, numPlayers: numPlayers), on: connection)
        broadcast(NetMessage(type: .playerJoined, count: connectedCount))

        WireFraming.receiveLoop(connection, onMessage: { [weak self] data in
            self?.handleIncoming(data, from: slot)
        }, onClose: { [weak self] in
            self?.handleDisconnect(slot)
        })

        if remoteJoined == numPlayers - 1 {
            broadcast(.stateEnvelope(.gameStart, state: engine.state))
            gameStarted = true
            engine.start()
        }
    }

    private func handleIncoming(_ data: Data, from slot: Int) {
        guard let msg = try? JSONDecoder().decode(NetMessage.self, from: data),
              msg.type == .action, let word = msg.word else { return }
        engine.attemptAction(playerNum: slot, raw: word)
    }

    private func handleDisconnect(_ slot: Int) {
        guard !isShuttingDown else { return }
        guard connections[slot] != nil else { return }
        connections.removeValue(forKey: slot)
        engine.forceRemove(slot, note: "Player \(slot) disconnected.")
    }

    private func broadcast(_ msg: NetMessage) {
        guard let data = WireFraming.encode(msg) else { return }
        for conn in connections.values {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Send to a single seat's connection. No-op for the host's own seat 1,
    /// which never has an entry in `connections`.
    private func sendToPlayer(_ slot: Int, _ msg: NetMessage) {
        guard let conn = connections[slot] else { return }
        WireFraming.send(msg, on: conn)
    }

    func stopHosting() {
        isShuttingDown = true
        listener?.cancel(); listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        engine.stop()
    }
}

// MARK: - LAN Browser (joiner side discovery)

final class LANBrowser: ObservableObject {
    @Published var hosts: [NWBrowser.Result] = []
    private var browser: NWBrowser?

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_shiritori._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.hosts = results.sorted { lhs, rhs in hostDisplayName(lhs) < hostDisplayName(rhs) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel(); browser = nil
        hosts = []
    }
}

func hostDisplayName(_ result: NWBrowser.Result) -> String {
    if case let .service(name, _, _, _) = result.endpoint { return name }
    return "Nearby game"
}

// MARK: - LAN Client (joiner side gameplay)

/// Doesn't run any rules itself — just mirrors whatever GameState the host
/// broadcasts and forwards this player's actions upstream, same division
/// of responsibility as `GameClient` in shiritori_net.py.
final class LANClient: ObservableObject {
    @Published var myPlayerNum: Int?
    @Published var numPlayers: Int = 2
    @Published var state = GameState.empty
    @Published var message = "Waiting for the host…"
    @Published var messageColor: Color = Palette.dim
    @Published var timeLeft = 30
    @Published var connectedWaitingText = "Connecting…"
    @Published var isConnected = false
    @Published var didDisconnect = false
    @Published var gameStarted = false
    @Published var isGameOver = false
    @Published var winner: Int?
    @Published var lastEvent: GameEvent = .none
    @Published var shakeTrigger = 0

    private var connection: NWConnection?

    func connect(to endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.isConnected = true
            case .failed, .cancelled: self?.handleClose()
            default: break
            }
        }
        conn.start(queue: .main)
        WireFraming.receiveLoop(conn, onMessage: { [weak self] data in
            self?.handleIncoming(data)
        }, onClose: { [weak self] in
            self?.handleClose()
        })
    }

    func sendAction(_ raw: String) {
        guard let connection else { return }
        WireFraming.send(NetMessage(type: .action, word: raw), on: connection)
    }

    /// A couple of commands are cheap to answer locally without waiting on
    /// a round trip; everything else (including /skip, /donate, and real
    /// words) goes to the host, which is the only one who can validate it.
    func submitCommandOrWord(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return }
        if cleaned == "/help" {
            message = "/skip · /donate <pts> <p> · /wordlist · /help"; messageColor = Palette.accent; return
        }
        if cleaned == "/wordlist" {
            message = "Used: " + state.wordList.joined(separator: ", "); messageColor = Palette.accent; return
        }
        sendAction(cleaned)
    }

    private func handleIncoming(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(NetMessage.self, from: data) else { return }
        switch msg.type {
        case .welcome:
            myPlayerNum = msg.playerNum
            numPlayers = msg.numPlayers ?? numPlayers
            connectedWaitingText = "You are Player \(msg.playerNum ?? 0) — waiting…"
        case .tick:
            timeLeft = msg.timeLeft ?? timeLeft
        case .gameStart:
            if let s = msg.asState { state = s }
            gameStarted = true
        case .stateUpdate:
            applyStateDiff(msg)
        case .msg:
            message = msg.text ?? ""
            messageColor = Color(hexString: msg.color) ?? Palette.red
            shakeTrigger += 1
        case .gameEnd:
            if let s = msg.asState { state = s }
            if let text = msg.displayText { message = text }
            winner = msg.winner
            isGameOver = true
            lastEvent = .gameOver(winner: msg.winner ?? 0)
            Haptics.winner()
        case .playerJoined:
            connectedWaitingText = "\(msg.count ?? 0)/\(numPlayers) connected"
        case .action:
            break
        }
    }

    /// The host only ever sends the *result* of a move as text + color, so
    /// this infers accepted/eliminated/other by diffing against the last
    /// known state — good enough to pick a matching flash/haptic locally.
    private func applyStateDiff(_ msg: NetMessage) {
        let old = state
        if let s = msg.asState { state = s }
        if let text = msg.displayText { message = text; messageColor = Color(hexString: msg.color) ?? Palette.accent }

        if state.wordList.count > old.wordList.count, let newWord = state.wordList.last {
            lastEvent = .accepted(word: newWord, points: newWord.count, player: old.currentPlayer)
            Haptics.accepted()
        } else if state.activePlayers.count < old.activePlayers.count {
            let removed = old.activePlayers.first { !state.activePlayers.contains($0) } ?? old.currentPlayer
            lastEvent = .eliminated(player: removed, isBot: false)
            Haptics.rejected()
        } else {
            lastEvent = .donated(from: old.currentPlayer, to: 0, amount: 0)
        }
    }

    private func handleClose() {
        guard !didDisconnect else { return }
        didDisconnect = true
        isConnected = false
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

