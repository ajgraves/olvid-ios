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

import UIKit
import BackgroundTasks
import os.log
import CoreData
import ObvEngine
import ObvUICoreData
import OlvidUtils


final class BackgroundTasksManager {
    
    private static let log = OSLog(subsystem: ObvMessengerConstants.logSubsystem, category: String(describing: BackgroundTasksManager.self))

    // Also used in info.plist in "Permitted background task scheduler identifiers"
    static let identifier = "io.olvid.background.tasks"

    private var observationTokens = [NSObjectProtocol]()

    private enum ObvSubBackgroundTask: CaseIterable, CustomStringConvertible {
                
        case cleanExpiredMessages
        case applyRetentionPolicies
        case updateBadge
        case listMessagesOnServer

        var description: String {
            switch self {
            case .cleanExpiredMessages:
                return "Clean Expired Message"
            case .applyRetentionPolicies:
                return "Apply retention policies"
            case .updateBadge:
                return "Update badge"
            case .listMessagesOnServer:
                return "List messages on server"
            }
        }

        func execute() async -> Bool {
            await withCheckedContinuation { cont in
                switch self {
                case .cleanExpiredMessages:
                    ObvMessengerInternalNotification.cleanExpiredMessagesBackgroundTaskWasLaunched { (success) in
                        cont.resume(returning: success)
                    }.postOnDispatchQueue()
                case .applyRetentionPolicies:
                    ObvMessengerInternalNotification.applyRetentionPoliciesBackgroundTaskWasLaunched { (success) in
                        cont.resume(returning: success)
                    }.postOnDispatchQueue()
                case .updateBadge:
                    ObvMessengerInternalNotification.updateBadgeBackgroundTaskWasLaunched { (success) in
                        cont.resume(returning: success)
                    }.postOnDispatchQueue()
                case .listMessagesOnServer:
                    ObvMessengerInternalNotification.listMessagesOnServerBackgroundTaskWasLaunched { (success) in
                        cont.resume(returning: success)
                    }.postOnDispatchQueue()
                }
            }
        }
    }
    
    struct TaskResult {
        let taskDescription: String
        let isSuccess: Bool
    }
    
    init() {
        os_log("🤿 Registering background task", log: Self.log, type: .info)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTasksManager.identifier, using: nil) { backgroundTask in
            //ObvDisplayableLogs.shared.log("Background Task executes")

            Task { [weak self] in
                
                let taskResults: [TaskResult] = try await withThrowingTaskGroup(of: TaskResult.self) { taskGroup in
                    
                    var taskResults = [TaskResult]()
                    
                    for task in ObvSubBackgroundTask.allCases {
                        //ObvDisplayableLogs.shared.log("Adding background Task '\(task.description)'")
                        taskGroup.addTask(priority: nil) {
                            //ObvDisplayableLogs.shared.log("Executing background Task '\(task.description)'")
                            let isSuccess = await task.execute()
                            //ObvDisplayableLogs.shared.log("Background Task '\(task.description)' did complete. Success is: \(isSuccess.description)")
                            return TaskResult(taskDescription: task.description, isSuccess: isSuccess)
                        }
                    }
                    
                    for try await taskResult in taskGroup {
                        taskResults.append(taskResult)
                    }
                    
                    return taskResults
                }
                
                os_log("🤿 All Background Tasks did complete", log: Self.log, type: .info)
                //ObvDisplayableLogs.shared.log("All Background Tasks did complete")
                for taskResult in taskResults {
                    os_log("🤿 Background Task '%{public}@' did complete. Success is: %{public}@", log: Self.log, type: .info, taskResult.taskDescription, taskResult.isSuccess.description)
                    //ObvDisplayableLogs.shared.log("Background Task '\(taskResult.taskDescription)' did complete. Success is: \(taskResult.isSuccess.description)")
                }
                backgroundTask.setTaskCompleted(success: true)

                await self?.scheduleBackgroundTasks()
            }
        }
        
        // Observe notifications in order to handle certain background tasks

        observationTokens.append(contentsOf: [
            ObvMessengerInternalNotification.observeListMessagesOnServerBackgroundTaskWasLaunched(queue: OperationQueue.main) { success in
                Task { [weak self] in
                    let obvEngine = await NewAppStateManager.shared.waitUntilAppIsInitialized()
                    await self?.processListMessagesOnServerBackgroundTaskWasLaunched(obvEngine: obvEngine, success: success)
                }
            },
        ])

    }

    
    deinit {
        observationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }


    private func earliestBeginDate(for task: ObvSubBackgroundTask, context: NSManagedObjectContext) -> Date? {
        switch task {
        case .cleanExpiredMessages:
            do {
                guard let expiration = try PersistedMessageExpiration.getEarliestExpiration(laterThan: Date(), within: context) else {
                    return nil
                }
                return expiration.expirationDate
            } catch {
                os_log("🤿 We could not get earliest message expiration: %{public}@", log: Self.log, type: .fault, error.localizedDescription)
                assertionFailure()
                return nil
            }
        case .applyRetentionPolicies:
            return Date(timeIntervalSinceNow: TimeInterval(hours: 1))
        case .updateBadge:
            do {
                guard let expiration = try PersistedDiscussionLocalConfiguration.getEarliestMuteExpirationDate(laterThan: Date(), within: context) else {
                    return nil
                }
                return expiration
            } catch {
                os_log("🤿 We could not get earliest mute expiration: %{public}@", log: Self.log, type: .fault, error.localizedDescription)
                assertionFailure()
                return nil
            }
        case .listMessagesOnServer:
            return Date(timeIntervalSinceNow: TimeInterval(hours: 2))
        }

    }

    func scheduleBackgroundTasks() async {
        // We do not schedule BG tasks when running in the simulator as they are not supported
        guard ObvMessengerConstants.isRunningOnRealDevice else { return }
        // We make sure the app was initialized. Otherwise, the shared stack is not garanteed to exist. Accessing it would crash the app.
        _ = await NewAppStateManager.shared.waitUntilAppIsInitialized()
        ObvStack.shared.performBackgroundTaskAndWait { (context) in
            var earliestBeginDate = Date.distantFuture
            for task in ObvSubBackgroundTask.allCases {
                if let date = self.earliestBeginDate(for: task, context: context) {
                    earliestBeginDate = min(date, earliestBeginDate)
                }
            }
            assert(earliestBeginDate > Date())
            let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
            request.earliestBeginDate = earliestBeginDate
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch let error {
                //ObvDisplayableLogs.shared.log("Could not schedule background task: \(error.localizedDescription)")
                os_log("🤿 Could not schedule background task: %{public}@", log: Self.log, type: .fault, error.localizedDescription)
            }
            //ObvDisplayableLogs.shared.log("Background task was submitted with earliest begin date \(String(describing: earliestBeginDate.description))")
            os_log("🤿 Background task was submitted with earliest begin date %{public}@", log: Self.log, type: .info, String(describing: earliestBeginDate.description))
        }

    }

    
    private func commonCompletion(obvTask: ObvSubBackgroundTask, backgroundTask: BGTask, success: Bool) {
        os_log("🤿 Background Task '%{public}' did complete. Success is: %{public}@", log: Self.log, type: .info, obvTask.description, success.description)
        //ObvDisplayableLogs.shared.log("Background Task '\(obvTask.description)' did complete. Success is: \(success.description)")
        backgroundTask.setTaskCompleted(success: success)
    }
    
    
    func cancelAllPendingBGTask() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
    
}
 

// MARK: - Implementing certain background tasks

extension BackgroundTasksManager {
    
    /// This method processes the notification sent after launching a background task for listing messages on the server.
    private func processListMessagesOnServerBackgroundTaskWasLaunched(obvEngine: ObvEngine, success: @escaping (Bool) -> Void) async {
        
        let tag = UUID()
        os_log("🤿 We are performing a background fetch. We tag it as %{public}@", log: Self.log, type: .info, tag.uuidString)
        
        let isSuccess: Bool
        do {
            try await obvEngine.downloadAllMessagesForOwnedIdentities()
            isSuccess = true
        } catch {
            assertionFailure()
            isSuccess = false
        }
        
        // Wait for some time for giving the app a change to process listed messages
        
        do {
            try await Task.sleep(seconds: 2)
        } catch {
            assertionFailure()
        }
        
        os_log("🤿 Calling the completion handler of the background fetch tagged as %{public}@. The result is %{public}@", log: Self.log, type: .info, tag.uuidString, isSuccess.description)

        return success(isSuccess)
        
    }

}
