//
//  ShortcutsView.swift
//  Canary
//
//  Created by Claude on 7/5/26.
//

import SwiftUI

/// Manages custom keyboard shortcuts (trigger → phrase): list,
/// swipe-to-delete, and an add form with inline validation.
struct ShortcutsView: View {
    @State private var shortcuts: [DictionaryStore.Shortcut] = []
    @State private var storeAvailable = false
    @State private var showingAdd = false
    @State private var newTrigger = ""
    @State private var newPhrase = ""
    @State private var addRejected = false
    /// Multi-select (trigger_lowers) while in edit mode, for bulk removal.
    @State private var selection = Set<String>()

    var body: some View {
        Group {
            if !storeAvailable {
                unavailableExplainer
            } else if shortcuts.isEmpty {
                ContentUnavailableView(
                    "No shortcuts yet",
                    systemImage: "arrow.right.circle",
                    description: Text(footerText)
                )
            } else {
                List(selection: $selection) {
                    Section(footer: Text(footerText)) {
                        ForEach(shortcuts) { shortcut in
                            HStack {
                                Text(shortcut.trigger)
                                    .fontWeight(.medium)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                    .imageScale(.small)
                                Text(shortcut.phrase)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .onDelete(perform: remove)
                    }
                }
            }
        }
        .navigationTitle("Shortcuts")
        .toolbar {
            if storeAvailable {
                ToolbarItemGroup(placement: .primaryAction) {
                    EditButton()
                    Button {
                        newTrigger = ""
                        newPhrase = ""
                        addRejected = false
                        showingAdd = true
                    } label: {
                        Label("Add Shortcut", systemImage: "plus")
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
        .alert("Add Shortcut", isPresented: $showingAdd) {
            TextField("shortcut (e.g. omw)", text: $newTrigger)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("phrase (e.g. On my way!)", text: $newPhrase)
            Button("Add") { add() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Typing the shortcut followed by a space expands it to the phrase.")
        }
        .alert("Invalid shortcut", isPresented: $addRejected) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Shortcuts are 2–24 letters, digits, or apostrophes with no spaces; phrases are a single line up to 200 characters.")
        }
        .onAppear(perform: reload)
    }

    private var footerText: String {
        "Text replacements from iOS Settings also expand; they're managed in Settings › General › Keyboard › Text Replacement, and a shortcut here overrides one there."
    }

    private var unavailableExplainer: some View {
        ContentUnavailableView {
            Label("Shortcuts unavailable", systemImage: "lock")
        } description: {
            Text("Enable Full Access for the Canary keyboard in Settings › General › Keyboard › Keyboards, then use the keyboard once.")
        }
    }

    private func reload() {
        if let store = DictionaryStore() {
            storeAvailable = true
            shortcuts = store.shortcuts()
        } else {
            storeAvailable = false
            shortcuts = []
        }
    }

    private func remove(at offsets: IndexSet) {
        guard let store = DictionaryStore() else { return }
        for index in offsets {
            store.removeShortcut(shortcuts[index].triggerLower)
        }
        reload()
        DictionarySync.shared.kick()
    }

    private func deleteSelected() {
        guard let store = DictionaryStore() else { return }
        for triggerLower in selection {
            store.removeShortcut(triggerLower)
        }
        selection.removeAll()
        reload()
        DictionarySync.shared.kick()
    }

    private func add() {
        guard let store = DictionaryStore() else { return }
        if store.addShortcut(trigger: newTrigger, phrase: newPhrase) {
            reload()
            DictionarySync.shared.kick()
        } else {
            addRejected = true
        }
    }
}

#Preview {
    NavigationStack {
        ShortcutsView()
    }
}
