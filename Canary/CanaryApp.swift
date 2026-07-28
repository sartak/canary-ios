//
//  CanaryApp.swift
//  Canary
//
//  Created by Shawn Moore on 7/29/25.
//

import SwiftUI
import UIKit

/// Registers for silent CloudKit pushes. CKSyncEngine subscribes on the
/// server and consumes the incoming notifications itself; the app only has
/// to opt in to remote notifications (no user prompt for silent pushes) and
/// kick the engine so a cold-launched background process syncs before its
/// runtime window closes. Latency becomes "usually soon after a change on
/// another device" rather than "next app open" - silent pushes are
/// best-effort and iOS throttles them, so the foreground kicks remain the
/// reliable fallback. The keyboard still can't receive pushes; it picks up
/// synced data at its next appearance via cache invalidation.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("CanaryApp: remote notification registration failed: \(error)")
    }

    // The completion-handler variant, deliberately: UIApplicationDelegate is
    // @MainActor in the SDK, and the async requirement's nonisolated thunk
    // can't send the non-Sendable userInfo dictionary into an isolated
    // implementation (Swift 6 error). This form is invoked on the main actor
    // directly - and holding the completion briefly keeps the background
    // window open for the engine's round trips instead of closing it
    // immediately.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        DictionarySync.shared.kick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            completionHandler(.newData)
        }
    }
}

@main
struct CanaryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
