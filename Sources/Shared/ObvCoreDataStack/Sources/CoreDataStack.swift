/*
 *  Olvid for iOS
 *  Copyright © 2019-2024 Olvid SAS
 *
 *  This file is part of Olvid for iOS.
 *
 *  Olvid is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License, version 3,
 *  as published by the Free Software Foundation.
 *
 *  Olvid is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with Olvid.  If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import CoreData
import SwiftUI
import OlvidUtils
import os.log

final public class CoreDataStack<PersistentContainerType: NSPersistentContainer> {
    
    private let modelName: String
    private let transactionAuthor: String
    private var notificationTokens = [NSObjectProtocol]()
    private let logger: Logger

    private var automaticallyMergesChangesFromParentWithAnimationWasCalled = false
    
    public init(modelName: String, transactionAuthor: String) {
        self.modelName = modelName
        self.transactionAuthor = transactionAuthor
        self.logger = Logger(subsystem: "io.olvid.messenger", category: "CoreDataStack-\(modelName)")
    }
    
    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    private lazy var persistentContainer: PersistentContainerType = {
        let container = PersistentContainerType(name: modelName)
        container.loadPersistentStores(completionHandler: { [weak self] (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
            // Prevent the store from being backed up to iCloud and iTunes
            self?.preventBackup(storeDescription: storeDescription)
        })
        return container
    }()

    
    private func preventBackup(storeDescription: NSPersistentStoreDescription) {
        guard var persistentStoreURL = storeDescription.url else {
            fatalError("Cannot determine Persistent Store URL")
        }
        guard FileManager.default.fileExists(atPath: persistentStoreURL.path) else { fatalError("Persistent store cannot be found at \(persistentStoreURL.path)") }
        do {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try persistentStoreURL.setResourceValues(resourceValues)
        } catch let error as NSError {
            fatalError("Error excluding \(persistentStoreURL) from backup \(error)")
        }
        logger.info("The store \(storeDescription.description) persistent store was excluded from iCloud and iTunes backup")

    }
    
    
    public var viewContext: NSManagedObjectContext {
        let viewContext = persistentContainer.viewContext
        automaticallyMergesChangesFromParentWithAnimation(for: viewContext)
        viewContext.transactionAuthor = transactionAuthor
        return viewContext
    }
    
    
    /// This wrapper makes it possible to avoir concurrency issues in the processing of the `NSManagedObjectContextDidSave` notification.
    private struct ViewContextWrapper: @unchecked Sendable {
        
        let viewContext: NSManagedObjectContext
        
        func mergeChanges(fromContextDidSave notification: Notification) {
            viewContext.perform {
                viewContext.mergeChanges(fromContextDidSave: notification)
            }
        }
        
    }
    

    private func automaticallyMergesChangesFromParentWithAnimation(for viewContext: NSManagedObjectContext) {
        guard !automaticallyMergesChangesFromParentWithAnimationWasCalled else { return }
        defer { automaticallyMergesChangesFromParentWithAnimationWasCalled = true }
        let NotificationName = Notification.Name.NSManagedObjectContextDidSave
        let viewContextWrapper = ViewContextWrapper(viewContext: viewContext)
        // It is important *not* to dispatch on the main queue right away because this could block the main thread in case it is waiting for the
        // (background) context thread to be saved. Instead, we asynchronously dispatch the merge on the main thread.
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NotificationName, object: nil, queue: nil) { (notification) in
            viewContextWrapper.mergeChanges(fromContextDidSave: notification)
        })
    }


    public func newBackgroundContext(file: StaticString = #fileID, line: Int = #line, function: StaticString = #function) -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.name = "\(file) - \(function) - Line \(line)"
        context.transactionAuthor = transactionAuthor
        return context
    }
    
    public func performBackgroundTask(file: StaticString = #fileID, line: Int = #line, function: StaticString = #function, _ block: @escaping (NSManagedObjectContext) -> Void) {
        let context = persistentContainer.newBackgroundContext()
        context.name = "\(file) - \(function) - Line \(line)"
        context.transactionAuthor = transactionAuthor
        context.perform {
            block(context)
        }
    }
    
    
    public func performBackgroundTaskAndWait(file: StaticString = #fileID, line: Int = #line, function: StaticString = #function, _ block: (NSManagedObjectContext) -> Void) {
        let context = persistentContainer.newBackgroundContext()
        context.name = "\(file) - \(function) - Line \(line)"
        context.transactionAuthor = transactionAuthor
        context.performAndWait {
            block(context)
        }
    }

    
    public func performBackgroundTaskAndWaitOrThrow(_ block: (NSManagedObjectContext) throws -> Void) throws {
        let context = persistentContainer.newBackgroundContext()
        context.transactionAuthor = transactionAuthor
        var error: Error? = nil
        context.performAndWait {
            do {
                try block(context)
            } catch let _error {
                error = _error
            }
        }
        if let error = error {
            throw error
        }
    }

    
    public func performBackgroundTaskAndWaitOrThrow<T>(_ block: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = persistentContainer.newBackgroundContext()
        context.transactionAuthor = transactionAuthor
        var error: Error? = nil
        var returnedValue: T!
        context.performAndWait {
            do {
                returnedValue = try block(context)
            } catch let _error {
                error = _error
            }
        }
        if let error = error {
            throw error
        }
        return returnedValue
    }

    
    public func managedObjectID(forURIRepresentation url: URL) -> NSManagedObjectID? {
        return persistentContainer.persistentStoreCoordinator.managedObjectID(forURIRepresentation: url)
    }
    
    public var persistentStoreCoordinator: NSPersistentStoreCoordinator {
        return persistentContainer.persistentStoreCoordinator
    }
}


extension CoreDataStack: ObvContextCreator {
    
    public func newBackgroundContext(flowId: FlowIdentifier, file: StaticString = #fileID, line: Int = #line, function: StaticString = #function) -> ObvContext {
        let context = newBackgroundContext()
        let obvContext = ObvContext(context: context, flowId: flowId, file: file, line: line, function: function)
        return obvContext
    }
    
}
