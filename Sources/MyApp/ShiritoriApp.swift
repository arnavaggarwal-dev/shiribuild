//
//  ShiritoriApp.swift
//  Shiritori
//
//  Native SwiftUI rebuild of the desktop Shiritori games (shiritori_bot.py /
//  shiritori_net.py). Same rules, same "cosmic nebula" palette, same bot
//  brain — new coat of paint and Bonjour instead of raw sockets.
//
//  SETUP (do this once in Xcode):
//   1. New Project → App → Interface: SwiftUI, Life Cycle: SwiftUI.
//   2. Delete the template ContentView.swift.
//   3. Drag this file + words_dictionary.json into the project (check
//      "Copy items if needed" and your app target).
//   4. Info tab on the target → add:
//        Privacy - Local Network Usage Description  → "Used to find nearby
//          Shiritori games on your Wi-Fi."
//        Bonjour services (array) → "_shiritori._tcp"
//      (Without these two keys, LAN hosting/joining will silently fail on
//      a real device — iOS gates Bonjour behind that permission.)
//   5. Build & run. That's it, no other dependencies.
//

import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - Root

struct RootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPrivacyDisclaimer = !PrivacyDisclaimer.hasBeenSeen

    var body: some View {
        ZStack {
            AnimatedNebulaBackground()
            Group {
                if !model.dict.isLoaded {
                    LoadingView()
                } else {
                    routedContent
                }
            }
            if showPrivacyDisclaimer {
                PrivacyDisclaimerView { showPrivacyDisclaimer = false }
            }
        }
        .environmentObject(model)
        .preferredColorScheme(.dark)
        .onAppear { model.loadDictionary() }
        .onChange(of: scenePhase) { _, phase in model.handleScenePhaseChange(phase) }
    }

    @ViewBuilder
    private var routedContent: some View {
        switch model.route {
        case .lobby: LobbyView()
        case .botSetup: BotSetupView()
        case .localSetup: LocalSetupView()
        case .hostSetup: HostSetupView()
        case .joinList: JoinListView(browser: model.browser)
        case .waitingHost(let total):
            if let host = model.lanHost { HostWaitingRoomView(host: host, total: total) }
        case .waitingClient:
            if let client = model.lanClient { ClientWaitingRoomView(client: client) }
        case .botGame: EngineGameScreen(mode: .bot)
        case .localGame: EngineGameScreen(mode: .local)
        case .hostGame: EngineGameScreen(mode: .host)
        case .clientGame: ClientGameScreen()
        case .winner(let info): WinnerView(info: info)
        case .disconnected: DisconnectedView()
        }
    }
}

// MARK: - App Entry

@main
struct ShiritoriGameApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
