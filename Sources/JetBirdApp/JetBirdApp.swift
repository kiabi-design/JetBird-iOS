//
//  JetBirdApp.swift
//  JetBirdApp
//
//  Main app entry point
//

import SwiftUI
import JetBirdCore
import JetBirdUI

@main
struct JetBirdApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var settings = AppSettingsStore()
    @StateObject private var spake2Manager = Spake2Manager()
    @StateObject private var psmtpDiscovery = PSMTPDiscovery()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloadManager)
                .environmentObject(settings)
                .environmentObject(spake2Manager)
                .environmentObject(psmtpDiscovery)
                .preferredColorScheme(settings.colorScheme)
                .onAppear {
                    // Initialize on launch
                    Task {
                        await initializeApp()
                    }
                }
        }
        .backgroundTask(.backgroundDownload)
    }

    private func initializeApp() async {
        // Load settings
        await settings.load()

        // Initialize filter engine
        await ContentFilterEngine.shared.recompile()

        // Schedule background task
        // (handled by DownloadManager.init)

        // Start PS4 discovery if wireless mode
        if settings.transferMode == .wireless {
            await psmtpDiscovery.start()
        }

        // Check for filter updates
        await FilterListUpdater.shared.updateIfNeeded()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Configure appearance
        configureAppearance()

        // Register for remote notifications (if needed for background downloads)
        // UNUserNotificationCenter.current().delegate = self

        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // Handle background URL session events
        // URLSession background completion
        completionHandler()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Schedule background task for continued downloads
        DownloadManager.shared.scheduleBackgroundTask()
    }

    private func configureAppearance() {
        // Navigation bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance

        // Tab bar appearance
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor.systemBackground

        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
}