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
