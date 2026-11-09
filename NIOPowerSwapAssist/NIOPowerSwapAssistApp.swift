//
//  NIOPowerSwapAssistApp.swift
//  NIOPowerSwapAssist
//
//  Created by 许懿赫 on 2025/1/2.
//

import SwiftUI

@main
struct NIOPowerSwapAssistApp: App {
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let preview = DesignPreviewMode.current {
                    DesignPreviewRoot(mode: preview)
                } else {
                    ContentView()
                        .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                }
                #else
                ContentView()
                    .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                #endif
            }
            .task {
                // Keep Keychain and WatchConnectivity work out of App.init so
                // SwiftUI can commit the first frame before configuration sync.
                await Task.yield()
                WatchConfigurationBridge.shared.activate()
                WatchConfigurationBridge.shared.sync(
                    BackendSettingsStore.shared.watchConfiguration()
                )
            }
        }
    }
}
