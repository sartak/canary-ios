//
//  CanaryApp.swift
//  Canary
//
//  Created by Shawn Moore on 7/29/25.
//

import SwiftUI

@main
struct CanaryApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                DictionarySync.shared.kick()
                SettingsSync.sync()
            }
        }
    }
}
