import SwiftUI

// MARK: - Star toggle

/// The one control that stars a word, wherever it appears — the in-game
/// header banner and every word in a past game's list. Observes the store so
/// all copies stay in sync when a word is unstarred somewhere else.
struct StarToggleButton: View {
    var word: String
    var size: CGFloat = 16

    @ObservedObject private var store = StarredStore.shared

    var body: some View {
        let starred = store.isStarred(word)
        Button {
            let nowStarred = store.toggleStar(word)
            if nowStarred {
                Haptics.accepted()
            } else {
                Haptics.tap()
            }
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(starred ? Palette.orange : Palette.dim)
                .contentShape(Rectangle())
                .padding(4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(starred ? "Unstar \(word)" : "Star \(word)")
    }
}

// MARK: - Game log

struct GameLogView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = GameLogStore.shared
    @State private var selected: GameLogEntry?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Game Log")
                    .font(GameFont.title(24))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 40)

                if store.entries.isEmpty {
                    EmptyStateCard(
                        icon: "clock.arrow.circlepath",
                        title: "No games yet",
                        message: "Finished games show up here — every word played, who won, and the final scores. You can turn logging off in Settings."
                    )
                } else {
                    if !AppSettings.loggingEnabled {
                        Text("Logging is currently off — new games won't be added.")
                            .font(GameFont.caption(11))
                            .foregroundStyle(Palette.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Lazy so off-screen rows aren't rendered until scrolled
                    // into view — same rows/order, cheaper as history grows
                    // (capped at 500 entries, but that's still a lot eagerly).
                    LazyVStack(spacing: 14) {
                        ForEach(store.entries) { entry in
                            Button {
                                Haptics.tap()
                                selected = entry
                            } label: {
                                GameLogRow(entry: entry)
                            }
                            .buttonStyle(PressableGlassButtonStyle())
                        }
                    }
                }

                GhostButton(title: "Back", systemImage: "chevron.left") {
                    model.route = .lobby
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
        }
        .sheet(item: $selected) { entry in
            GameLogDetailView(entry: entry)
        }
    }
}

private struct GameLogRow: View {
    var entry: GameLogEntry

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.accent.opacity(0.18))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
                    )
                Image(systemName: entry.mode.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.mode.label)
                        .font(GameFont.headline(14))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Text("\(entry.words.count) words")
                        .font(GameFont.caption(10))
                        .foregroundStyle(Palette.dim)
                }
                Text("\(entry.winnerName) won · \(entry.numPlayers) players")
                    .font(GameFont.body(12))
                    .foregroundStyle(Palette.green)
                Text(Self.formatter.string(from: entry.date))
                    .font(GameFont.caption(10))
                    .foregroundStyle(Palette.dim)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.dim)
        }
        .padding(14)
        .glassCard(border: Palette.border)
    }
}

// MARK: - Game log detail

struct GameLogDetailView: View {
    var entry: GameLogEntry
    @Environment(\.dismiss) private var dismiss

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedNebulaBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.mode.label)
                                .font(GameFont.headline(15))
                                .foregroundStyle(Palette.accent)
                            Text(Self.formatter.string(from: entry.date))
                                .font(GameFont.caption(11))
                                .foregroundStyle(Palette.dim)
                            Text("\(entry.winnerName) won")
                                .font(GameFont.title(20))
                                .foregroundStyle(Palette.green)
                            if let difficulty = entry.botDifficulty {
                                Text("Bot difficulty \(difficulty)")
                                    .font(GameFont.caption(11))
                                    .foregroundStyle(Palette.dim)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassCard()

                        scoresCard

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Words played")
                                    .font(GameFont.headline(14))
                                    .foregroundStyle(Palette.text)
                                Spacer()
                                Text("tap ☆ to save")
                                    .font(GameFont.caption(10))
                                    .foregroundStyle(Palette.dim)
                            }

                            ForEach(Array(entry.words.enumerated()), id: \.offset) { _, word in
                                HStack(spacing: 10) {
                                    Text(word)
                                        .font(GameFont.body(15))
                                        .foregroundStyle(Palette.text)
                                    Spacer()
                                    Text("\(word.count) pts")
                                        .font(GameFont.caption(10))
                                        .foregroundStyle(Palette.dim)
                                    StarToggleButton(word: word)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card2))
                            }
                        }
                        .padding(16)
                        .glassCard()

                        Spacer(minLength: 20)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Game Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var scoresCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Final scores")
                .font(GameFont.headline(14))
                .foregroundStyle(Palette.text)
            ForEach(Array(entry.scores.enumerated()), id: \.offset) { index, score in
                let player = index + 1
                HStack {
                    Text(entry.name(for: player))
                        .font(GameFont.body(13))
                        .foregroundStyle(player == entry.winner ? Palette.green : Palette.dim)
                    if player == entry.myPlayerNum {
                        Text("(you)")
                            .font(GameFont.caption(10))
                            .foregroundStyle(Palette.accent)
                    }
                    Spacer()
                    Text("\(score)")
                        .font(GameFont.mono(15))
                        .foregroundStyle(player == entry.winner ? Palette.green : Palette.text)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }
}
