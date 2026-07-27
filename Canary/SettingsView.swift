//
//  SettingsView.swift
//  Canary
//
//  Created by Claude on 7/27/26.
//

import SwiftUI

/// App-side keyboard settings: the same three toggles the keyboard exposes
/// on its number layer (shared through the app-group facade, so each side
/// sees the other's flips), plus the nuclear option — reset all typing data
/// on this device and in iCloud.
struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var swipeOnly = KeyboardSettings.swipeOnlyMode
    @State private var autocorrect = !KeyboardSettings.autocorrectUserDisabled
    @State private var debugVisualization = KeyboardSettings.debugVisualizationEnabled
    @State private var predictionCount = KeyboardSettings.predictionWordCount
    @State private var collectStats = KeyboardSettings.statsCollectionEnabled
    @State private var confirmingReset = false
    @State private var resetDone = false

    var body: some View {
        List {
            Section {
                Toggle("Swipe-Only Mode", isOn: $swipeOnly)
                    .onChange(of: swipeOnly) { _, value in
                        // Guarded: refreshSettings' programmatic re-reads must
                        // not re-stamp values that didn't change (a spurious
                        // stamp could win a cross-device merge).
                        guard value != KeyboardSettings.swipeOnlyMode else { return }
                        KeyboardSettings.swipeOnlyMode = value
                        SettingsSync.sync()
                    }
                Toggle("Autocorrect", isOn: $autocorrect)
                    .onChange(of: autocorrect) { _, value in
                        guard value != !KeyboardSettings.autocorrectUserDisabled else { return }
                        KeyboardSettings.autocorrectUserDisabled = !value
                        SettingsSync.sync()
                    }
                Toggle("Debug Visualization", isOn: $debugVisualization)
                    .onChange(of: debugVisualization) { _, value in
                        guard value != KeyboardSettings.debugVisualizationEnabled else { return }
                        KeyboardSettings.debugVisualizationEnabled = value
                        SettingsSync.sync()
                    }
                Stepper(value: $predictionCount, in: 0...5) {
                    HStack {
                        Text("AI Suggestions")
                        Spacer()
                        Text(predictionCount == 0 ? "Off" : "\(predictionCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .onChange(of: predictionCount) { _, value in
                    guard value != KeyboardSettings.predictionWordCount else { return }
                    KeyboardSettings.predictionWordCount = value
                    SettingsSync.sync()
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("The first three toggles mirror the keyboard's number-layer keys; the keyboard adopts changes the next time it appears. AI Suggestions is how many next words from Apple's on-device model fill the empty suggestion bar (0 turns them off; Apple Intelligence devices only; nothing leaves the phone).")
            }

            Section {
                Toggle("Collect Typing Stats", isOn: $collectStats)
                    .onChange(of: collectStats) { _, value in
                        guard value != KeyboardSettings.statsCollectionEnabled else { return }
                        KeyboardSettings.statsCollectionEnabled = value
                    }
            } header: {
                Text("This Device")
            } footer: {
                Text("Opt-in and per-device (never synced): records keystrokes — including which keys — words typed, and correction events for the Stats screen. Off by default; learning and suggestions work either way.")
            }

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
        .onAppear(perform: refreshSettings)
        // onAppear fires on navigation push, NOT when the app returns from
        // background — which is exactly when the keyboard (used in some other
        // app) flipped a toggle. Re-read on activation too.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshSettings()
            }
        }
    }

    /// The keyboard (or another device via SettingsSync) may have flipped
    /// these since the view last read them.
    private func refreshSettings() {
        swipeOnly = KeyboardSettings.swipeOnlyMode
        autocorrect = !KeyboardSettings.autocorrectUserDisabled
        debugVisualization = KeyboardSettings.debugVisualizationEnabled
        collectStats = KeyboardSettings.statsCollectionEnabled
        predictionCount = KeyboardSettings.predictionWordCount
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
