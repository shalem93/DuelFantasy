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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
