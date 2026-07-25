import SwiftUI

// MARK: - Starred words

struct StarredView: View {
    @ObservedObject private var store = StarredStore.shared

    /// nil == the "All" chip.
    @State private var activeFolder: UUID?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: StarredWord?
    @State private var pendingFolderDelete: WordFolder?

    /// One enum-driven sheet rather than two `item:` sheets on the same view —
    /// SwiftUI only reliably honours one sheet per view, so the second would
    /// silently never open.
    private enum ActiveSheet: Identifiable {
        case definition(StarredWord)
        case folders(StarredWord)

        var id: String {
            switch self {
            case .definition(let w): return "def-\(w.id)"
            case .folders(let w): return "folder-\(w.id)"
            }
        }
    }
    @State private var activeSheet: ActiveSheet?

    private var visibleWords: [StarredWord] {
        store.words(in: activeFolder)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Starred Words")
                    .font(GameFont.title(24))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 14)

                if store.words.isEmpty {
                    EmptyStateCard(
                        icon: "star",
                        title: "No starred words yet",
                        message: "Starred words appear here. Tap ☆ next to the current word while you're playing, or star any word from a past game in the Logs tab."
                    )
                } else {
                    folderChips

                    if visibleWords.isEmpty {
                        EmptyStateCard(
                            icon: "folder",
                            title: "Nothing in this folder",
                            message: "Long-press a word in All to file it in here."
                        )
                    } else {
                        ForEach(visibleWords) { entry in
                            wordRow(entry)
                        }
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .definition(let entry): WordDefinitionView(entry: entry)
            case .folders(let entry): FolderAssignmentView(entry: entry)
            }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.createFolder(named: name) }
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Remove this word?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { entry in
            Button("Remove", role: .destructive) {
                store.delete(entry)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text("\u{201C}\(entry.word)\u{201D} will be removed from your starred words.")
        }
        .alert("Delete this folder?",
               isPresented: Binding(get: { pendingFolderDelete != nil },
                                    set: { if !$0 { pendingFolderDelete = nil } }),
               presenting: pendingFolderDelete) { folder in
            Button("Delete", role: .destructive) {
                if activeFolder == folder.id { activeFolder = nil }
                store.deleteFolder(folder.id)
                pendingFolderDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingFolderDelete = nil }
        } message: { _ in
            Text("The folder goes away but the words stay starred — you'll still find them under All.")
        }
    }

    // MARK: folder chips

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", count: store.words.count, isActive: activeFolder == nil) {
                    activeFolder = nil
                }

                ForEach(store.folders) { folder in
                    chip(title: folder.name,
                         count: store.words(in: folder.id).count,
                         isActive: activeFolder == folder.id) {
                        activeFolder = folder.id
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingFolderDelete = folder
                        } label: {
                            Label("Delete folder", systemImage: "trash")
                        }
                    }
                }

                Button {
                    Haptics.tap()
                    showNewFolder = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(GameFont.caption(11))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(title: String, count: Int, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .font(GameFont.caption(9))
                    .opacity(0.7)
            }
            .font(GameFont.caption(11))
            .foregroundStyle(isActive ? Palette.bg : Palette.dim)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                Capsule().fill(isActive ? Palette.accent : Color.clear)
            )
            .overlay(Capsule().strokeBorder(isActive ? Color.clear : Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: word row

    private func wordRow(_ entry: StarredWord) -> some View {
        Button {
            Haptics.tap()
            activeSheet = .definition(entry)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.word)
                        .font(GameFont.headline(16))
                        .foregroundStyle(Palette.text)
                    if let definition = entry.cachedDefinition,
                       let first = definition.meanings.first?.definitions.first {
                        Text(first.text)
                            .font(GameFont.caption(11))
                            .foregroundStyle(Palette.dim)
                            .lineLimit(1)
                    } else {
                        Text("Tap to look up")
                            .font(GameFont.caption(11))
                            .foregroundStyle(Palette.dim)
                    }
                }
                Spacer()
                if !entry.folderIDs.isEmpty {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.dim)
            }
            .padding(14)
            .glassCard(border: Palette.border)
        }
        .buttonStyle(PressableGlassButtonStyle())
        .contextMenu {
            Button {
                activeSheet = .folders(entry)
            } label: {
                Label("Add to folder…", systemImage: "folder.badge.plus")
            }
            Button(role: .destructive) {
                pendingDelete = entry
            } label: {
                Label("Remove word", systemImage: "trash")
            }
        }
    }
}

// MARK: - Folder assignment

/// A word can sit in any number of folders at once, so this is a checklist
/// rather than a single picker.
struct FolderAssignmentView: View {
    var entry: StarredWord
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StarredStore.shared

    private var current: StarredWord? {
        store.words.first { $0.id == entry.id }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedNebulaBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        Text(entry.word)
                            .font(GameFont.title(22))
                            .foregroundStyle(Palette.accent)
                            .padding(.top, 8)

                        if store.folders.isEmpty {
                            EmptyStateCard(
                                icon: "folder.badge.plus",
                                title: "No folders yet",
                                message: "Create one from the Starred tab, then come back to file this word."
                            )
                        } else {
                            ForEach(store.folders) { folder in
                                let isIn = current?.folderIDs.contains(folder.id) ?? false
                                Button {
                                    Haptics.tap()
                                    if let live = current {
                                        store.setFolder(folder.id, on: live, to: !isIn)
                                    }
                                } label: {
                                    HStack {
                                        Text(folder.name)
                                            .font(GameFont.body(14))
                                            .foregroundStyle(Palette.text)
                                        Spacer()
                                        Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isIn ? Palette.green : Palette.dim)
                                    }
                                    .padding(14)
                                    .glassCard(border: Palette.border)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Folders")
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

// MARK: - Definition

struct WordDefinitionView: View {
    var entry: StarredWord
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StarredStore.shared

    @State private var definition: CachedDefinition?
    @State private var failure: DictionaryLookupFailure?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedNebulaBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        if let definition {
                            definitionBody(definition)
                        } else if isLoading {
                            VStack(spacing: 12) {
                                BouncingDotsView()
                                Text("Looking it up…")
                                    .font(GameFont.caption(11))
                                    .foregroundStyle(Palette.dim)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(30)
                            .glassCard()
                        } else if let failure {
                            failureCard(failure)
                        } else if !AppSettings.definitionLookupEnabled {
                            EmptyStateCard(
                                icon: "wifi.slash",
                                title: "Online lookup is off",
                                message: "Turn on \"Look up definitions online\" in Settings to fetch meanings and example sentences."
                            )
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Definition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.word)
                .font(GameFont.display(32))
                .foregroundStyle(Palette.glow)
                .glow(Palette.glow, radius: 12, opacity: 0.3)
            if let phonetic = definition?.phonetic, !phonetic.isEmpty {
                Text(phonetic)
                    .font(GameFont.body(13))
                    .foregroundStyle(Palette.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private func definitionBody(_ definition: CachedDefinition) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(definition.meanings.enumerated()), id: \.offset) { _, meaning in
                VStack(alignment: .leading, spacing: 8) {
                    if !meaning.partOfSpeech.isEmpty {
                        Text(meaning.partOfSpeech)
                            .font(GameFont.caption(11))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                    }
                    ForEach(Array(meaning.definitions.enumerated()), id: \.offset) { index, def in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(def.text)")
                                .font(GameFont.body(14))
                                .foregroundStyle(Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassCard()
            }

            exampleCard(definition)

            Text("Source: \(definition.source)")
                .font(GameFont.caption(10))
                .foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Example sentences are missing from a lot of entries — and the last
    /// provider in the chain has none at all — so this always renders,
    /// saying so plainly rather than leaving a gap.
    private func exampleCard(_ definition: CachedDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Example")
                .font(GameFont.caption(11))
                .foregroundStyle(Palette.green)
            if let example = definition.firstExample {
                Text("\u{201C}\(example)\u{201D}")
                    .font(GameFont.body(14))
                    .foregroundStyle(Palette.text)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No example available for this word.")
                    .font(GameFont.body(13))
                    .foregroundStyle(Palette.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(border: Palette.border, fill: Palette.card2)
    }

    private func failureCard(_ failure: DictionaryLookupFailure) -> some View {
        VStack(spacing: 12) {
            Image(systemName: failure == .notFound ? "questionmark.circle" : "wifi.exclamationmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.dim)
            Text(failure.message)
                .font(GameFont.body(13))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
            if failure == .unreachable {
                GhostButton(title: "Retry", systemImage: "arrow.clockwise") {
                    Task { await load() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassCard()
    }

    // MARK: loading

    private func loadIfNeeded() async {
        if let cached = store.words.first(where: { $0.id == entry.id })?.cachedDefinition {
            definition = cached
            return
        }
        await load()
    }

    private func load() async {
        guard AppSettings.definitionLookupEnabled else { return }
        guard !isLoading else { return }
        isLoading = true
        failure = nil

        let result = await DictionaryService.shared.lookup(entry.word)

        isLoading = false
        switch result {
        case .success(let fetched):
            definition = fetched
            store.attachDefinition(fetched, to: entry.id)
        case .failure(let reason):
            failure = reason
        }
    }
}
