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
import os.log
import OlvidUtils
import ObvUICoreData
import ObvAppCoreConstants


final class DeleteDraftFyleJoinOperation: OperationWithSpecificReasonForCancel<DeleteDraftFyleJoinOperationReasonForCancel>, @unchecked Sendable {

    private let draftFyleJoinObjectID: TypeSafeManagedObjectID<PersistedDraftFyleJoin>

    private let log = OSLog(subsystem: ObvAppCoreConstants.logSubsystem, category: String(describing: DeleteDraftFyleJoinOperation.self))

    init(draftFyleJoinObjectID: TypeSafeManagedObjectID<PersistedDraftFyleJoin>) {
        self.draftFyleJoinObjectID = draftFyleJoinObjectID
        super.init()
    }

    override func main() {
        ObvStack.shared.performBackgroundTaskAndWait { (context) in
            guard let persistedDraftFyleJoin = PersistedDraftFyleJoin.get(objectID: draftFyleJoinObjectID, within: context) else {
                return cancel(withReason: .couldNotFindDraftFyleJoin)
            }
            let draft = persistedDraftFyleJoin.draft
            let draftFyleJoinPermanentID = try? persistedDraftFyleJoin.objectPermanentID
            // We expect draft to be non-nil
            draft?.removeDraftFyleJoin(persistedDraftFyleJoin)
            do {
                try context.save(logOnFailure: log)
            } catch(let error) {
                return cancel(withReason: .coreDataError(error: error))
            }

            if let draft, let draftPermanentID = try? draft.objectPermanentID, let draftFyleJoinPermanentID {
                ObvMessengerInternalNotification.draftFyleJoinWasDeleted(discussionPermanentID: draft.discussion.discussionPermanentID,
                                                                         draftPermanentID: draftPermanentID,
                                                                         draftFyleJoinPermanentID: draftFyleJoinPermanentID)
                .postOnDispatchQueue()
            }
        }
    }

}

enum DeleteDraftFyleJoinOperationReasonForCancel: LocalizedErrorWithLogType {

    case coreDataError(error: Error)
    case couldNotFindDraftFyleJoin

    var logType: OSLogType {
        switch self {
        case .coreDataError:
            return .fault
        case .couldNotFindDraftFyleJoin:
            return .error
        }
    }

    var errorDescription: String? {
        switch self {
        case .coreDataError(error: let error):
            return "Core Data error: \(error.localizedDescription)"
        case .couldNotFindDraftFyleJoin:
            return "Could not find draft fyle join in database"
        }
    }


}
