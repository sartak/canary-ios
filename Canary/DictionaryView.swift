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
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "No learned words yet",
                    systemImage: "book",
                    description: Text("Words you defend from autocorrect or type repeatedly appear here.")
                )
            } else {
                List(selection: $selection) {
                    Section(footer: syncFooter) {
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
        } else {
            storeAvailable = false
            entries = []
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

    private func deleteSelected() {
        guard let store = DictionaryStore() else { return }
        for wordLower in selection {
            store.unlearn(wordLower)
        }
        selection.removeAll()
        reload()
        DictionarySync.shared.kick()
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
