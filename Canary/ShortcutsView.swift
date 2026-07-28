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
    @State private var newOpensURL = false
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
                                Image(systemName: shortcut.opensURL ? "arrow.up.right.square" : "arrow.right")
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
                        newOpensURL = false
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
        .sheet(isPresented: $showingAdd) {
            // A sheet rather than an alert: the conditional open-as-URL
            // toggle can't live in an alert.
            NavigationStack {
                Form {
                    Section {
                        TextField("shortcut (e.g. omw)", text: $newTrigger)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("phrase (e.g. On my way!)", text: $newPhrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("Typing the shortcut followed by a space expands it to the phrase.")
                    }
                    if phraseLooksLikeURL {
                        Section {
                            Toggle("Open as URL when triggered", isOn: $newOpensURL)
                        } footer: {
                            Text("On: triggering jumps straight to this URL. Off: the URL is typed as text — for sending someone the link.")
                        }
                    }
                }
                .navigationTitle("Add Shortcut")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { add() }
                            .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                                      || newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Invalid shortcut", isPresented: $addRejected) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Shortcuts are 2–24 letters, digits, or apostrophes with no spaces; phrases are a single line up to 200 characters.")
        }
        .onAppear(perform: reload)
    }

    /// Whether the phrase reads as a URL: it starts with a scheme, nothing
    /// fuzzier ("v2.0" is not a URL). Any scheme counts — shortcuts:// and
    /// friends are legitimate targets. Only gates showing the toggle.
    private var phraseLooksLikeURL: Bool {
        let phrase = newPhrase.trimmingCharacters(in: .whitespaces).lowercased()
        guard !phrase.contains(" "), let schemeEnd = phrase.range(of: "://") else { return false }
        let scheme = phrase[..<schemeEnd.lowerBound]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
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
        // The toggle only applies when it was visible for this phrase.
        let opensURL = newOpensURL && phraseLooksLikeURL
        if store.addShortcut(trigger: newTrigger, phrase: newPhrase, opensURL: opensURL) {
            showingAdd = false
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
