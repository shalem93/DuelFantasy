//
//  GameOnApp.swift
//  GameOn
//
//  Created by Samuel Halem on 3/3/26.
//

import SwiftUI
import CoreData

@main
struct GameOnApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var auth = AuthViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Drop any oversized legacy blobs out of UserDefaults BEFORE anything
        // reads/writes it. The CFPreferences domain has a 4MB ceiling; once
        // exceeded, writes fail silently and reads corrupt (`decode: bad range`),
        // which destabilized the RR total. Caches regenerate; settings are tiny.
        FileBlobStore.sweepOversizedDefaults()
        // MetricKit crash reporting: receives the previous run's crash/hang
        // diagnostics at launch and uploads them to the `crash_reports` table.
        CrashReporter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated {
                    ContentView()
                } else {
                    AuthView()
                }
            }
            .environmentObject(auth)
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            .preferredColorScheme(.light)
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await auth.refreshSessionIfNeeded() }
                }
            }
        }
    }
}
