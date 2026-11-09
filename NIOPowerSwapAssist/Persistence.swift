//
//  Persistence.swift
//  NIOPowerSwapAssist
//
//  Created by 许懿赫 on 2025/1/2.
//

import CoreData
import OSLog

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        for i in 0..<10 {
            let newItem = SwapStations(context: viewContext)
            newItem.index = Int16(i)
        }
        do {
            try viewContext.save()
        } catch {
            Logger.persistence.error("Preview store save failed: \(error.localizedDescription, privacy: .public)")
        }
        return result
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "NIOPowerSwapAssist")
        container.persistentStoreDescriptions.forEach {
            $0.shouldMigrateStoreAutomatically = true
            $0.shouldInferMappingModelAutomatically = true
        }
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error {
                Logger.persistence.fault("Persistent store failed to load: \(error.localizedDescription, privacy: .public)")
            }
        })
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}

private extension Logger {
    static let persistence = Logger(subsystem: "NIOPowerSwapAssist", category: "Persistence")
}
