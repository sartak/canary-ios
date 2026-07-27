//
//  ContentView.swift
//  Canary
//
//  Created by Shawn Moore on 7/29/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Keyboard") {
                    NavigationLink {
                        DictionaryView()
                    } label: {
                        Label("Dictionary", systemImage: "book")
                    }
                    NavigationLink {
                        ShortcutsView()
                    } label: {
                        Label("Shortcuts", systemImage: "arrow.right.circle")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Canary")
        }
    }
}

#Preview {
    ContentView()
}
