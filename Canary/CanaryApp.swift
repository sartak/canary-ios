//
//  CanaryApp.swift
//  Canary
//
//  Created by Shawn Moore on 7/29/25.
//

import BackgroundTasks
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
    /// Must appear in Info.plist's BGTaskSchedulerPermittedIdentifiers.
    static let refreshTaskID = "net.rpglanguage.Canary.sync"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        // Scheduled background refresh closes the send-side gap: the
        // keyboard only marks rows dirty, so keyboard-made changes need app
        // runtime to upload. iOS grants these opportunistically (typically a
        // few times a day); pushes remain the receive path and foreground
        // kicks the reliable fallback.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleRefresh(refresh)
        }
        Self.scheduleRefresh()
        return true
    }

    /// Always re-armed (each request is one-shot). The earliest-begin date
    /// is a request, not a promise - iOS decides the actual cadence.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("CanaryApp: background refresh scheduling failed: \(error)")
        }
    }

    static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            DictionarySync.shared.kick()
            SettingsSync.sync()
            // kick() is fire-and-forget; hold the task open long enough for
            // the engine's fetch+send round trips, then report done.
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
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
            } else if phase == .background {
                AppDelegate.scheduleRefresh()
            }
        }
    }
}
