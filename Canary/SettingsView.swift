//
//  SettingsView.swift
//  Canary
//
//  Created by Claude on 7/27/26.
//

import SwiftUI

/// App-side keyboard settings. Currently just the nuclear option: reset all
/// typing data (learned words, usage history, shortcuts, correction logs) on
/// this device and in iCloud. Keyboard toggles are not affected — they live
/// on the keyboard itself.
struct SettingsView: View {
    @State private var confirmingReset = false
    @State private var resetDone = false

    var body: some View {
        List {
            Section {
                Button("Reset Typing Data…", role: .destructive) {
                    confirmingReset = true
                }
                .disabled(DictionaryStore() == nil)
            } footer: {
                Text("Removes learned words, usage history, shortcuts, and correction logs from this device and iCloud. Keyboard toggles (swipe-only, autocorrect, debug) are not affected.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset all typing data?", isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Typing data reset", isPresented: $resetDone) {
            Button("OK", role: .cancel) {}
        }
    }

    private func reset() {
        DictionaryStore()?.resetAllTypingData()
        DictionarySync.shared.resetCloudData()
        resetDone = true
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
