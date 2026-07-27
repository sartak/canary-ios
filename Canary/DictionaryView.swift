//
//  DictionaryView.swift
//  Canary
//
//  Created by Claude on 7/5/26.
//

import SwiftUI

/// Manages the keyboard's learned words: list with usage counts,
/// swipe-to-remove (tombstoned so the word doesn't immediately re-promote),
/// and manual add.
struct DictionaryView: View {
    @State private var entries: [DictionaryStore.Entry] = []
    @State private var tombstones: [DictionaryStore.Tombstone] = []
    @State private var storeAvailable = false
    @State private var showingAdd = false
    @State private var newWord = ""
    @State private var addRejected = false
    /// Multi-select (word_lowers) while in edit mode, for bulk removal.
    @State private var selection = Set<String>()

    var body: some View {
        Group {
            if !storeAvailable {
                unavailableExplainer
            } else if entries.isEmpty && tombstones.isEmpty {
                ContentUnavailableView(
                    "No learned words yet",
                    systemImage: "book",
                    description: Text("Words you defend from autocorrect or type repeatedly appear here.")
                )
            } else {
                List(selection: $selection) {
                    Section(footer: tombstones.isEmpty ? syncFooter : nil) {
                        ForEach(entries) { entry in
                            HStack {
                                Text(entry.word)
                                Spacer()
                                Text("\(entry.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .onDelete(perform: unlearn)
                    }
                    if !tombstones.isEmpty {
                        Section {
                            ForEach(tombstones) { tombstone in
                                Text(tombstone.wordLower)
                                    .foregroundStyle(.secondary)
                            }
                            .onDelete(perform: hardDelete)
                        } header: {
                            Text("Removed")
                        } footer: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Removed words won't be re-learned by typing (defending one from autocorrect still brings it back). Deleting here erases the block and the word's history, so it can be learned fresh.")
                                syncFooter
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Dictionary")
        .toolbar {
            if storeAvailable {
                ToolbarItemGroup(placement: .primaryAction) {
                    EditButton()
                    Button {
                        newWord = ""
                        addRejected = false
                        showingAdd = true
                    } label: {
                        Label("Add Word", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if !selection.isEmpty {
                        Button("Remove \(selection.count) Selected", role: .destructive) {
                            deleteSelected()
                        }
                    }
                }
            }
        }
        .alert("Add Word", isPresented: $showingAdd) {
            TextField("word", text: $newWord)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { add() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Letters and interior apostrophes, 2–24 characters.")
        }
        .alert("Not a valid word", isPresented: $addRejected) {
            Button("OK", role: .cancel) {}
        }
        .onAppear(perform: reload)
    }

    private var syncFooter: some View {
        Group {
            if let last = DictionarySync.lastSync {
                Text("Synced via iCloud when this app opens. Last sync \(last.formatted(.relative(presentation: .named))).")
            } else {
                Text("Syncs via iCloud when this app opens.")
            }
        }
    }

    private var unavailableExplainer: some View {
        ContentUnavailableView {
            Label("Dictionary unavailable", systemImage: "lock")
        } description: {
            Text("Enable Full Access for the Canary keyboard in Settings › General › Keyboard › Keyboards, then use the keyboard once. Learned words will appear here.")
        }
    }

    private func reload() {
        if let store = DictionaryStore() {
            storeAvailable = true
            entries = store.entries()
            tombstones = store.tombstones()
        } else {
            storeAvailable = false
            entries = []
            tombstones = []
        }
    }

    private func unlearn(at offsets: IndexSet) {
        guard let store = DictionaryStore() else { return }
        for index in offsets {
            store.unlearn(entries[index].wordLower)
        }
        reload()
        DictionarySync.shared.kick()
    }

    /// Selection can span both sections; ids can't collide (a word is either
    /// learned or tombstoned, never both). Learned → un-learn (tombstone);
    /// tombstoned → hard delete (erase, incl. the CloudKit record).
    private func deleteSelected() {
        guard let store = DictionaryStore() else { return }
        let tombstoned = Set(tombstones.map(\.wordLower))
        var hardDeleted: [String] = []
        for wordLower in selection {
            if tombstoned.contains(wordLower) {
                store.hardDeleteWord(wordLower)
                hardDeleted.append(wordLower)
            } else {
                store.unlearn(wordLower)
            }
        }
        selection.removeAll()
        reload()
        DictionarySync.shared.hardDeleteWords(hardDeleted)
        DictionarySync.shared.kick()
    }

    private func hardDelete(at offsets: IndexSet) {
        guard let store = DictionaryStore() else { return }
        var deleted: [String] = []
        for index in offsets {
            store.hardDeleteWord(tombstones[index].wordLower)
            deleted.append(tombstones[index].wordLower)
        }
        reload()
        DictionarySync.shared.hardDeleteWords(deleted)
    }

    private func add() {
        guard let store = DictionaryStore() else { return }
        if store.add(newWord) {
            reload()
            DictionarySync.shared.kick()
        } else {
            addRejected = true
        }
    }
}

#Preview {
    NavigationStack {
        DictionaryView()
    }
}
