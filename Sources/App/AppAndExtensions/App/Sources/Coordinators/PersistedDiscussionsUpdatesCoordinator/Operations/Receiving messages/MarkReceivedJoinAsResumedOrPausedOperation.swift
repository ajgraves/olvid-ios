/*
 *  Olvid for iOS
 *  Copyright © 2019-2023 Olvid SAS
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
import os.log
import CoreData
import OlvidUtils
import ObvTypes
import ObvUICoreData
import ObvAppCoreConstants


final class MarkReceivedJoinAsResumedOrPausedOperation: ContextualOperationWithSpecificReasonForCancel<CoreDataOperationReasonForCancel>, @unchecked Sendable {

    private let log = OSLog(subsystem: ObvAppCoreConstants.logSubsystem, category: String(describing: MarkReceivedJoinAsResumedOrPausedOperation.self))

    private let ownedCryptoId: ObvCryptoId
    private let messageIdentifierFromEngine: Data
    private let attachmentNumber: Int
    private let resumeOrPause: ResumeOrPause

    enum ResumeOrPause {
        case resume
        case pause
    }
    
    init(ownedCryptoId: ObvCryptoId, messageIdentifierFromEngine: Data, attachmentNumber: Int, resumeOrPause: ResumeOrPause) {
        self.ownedCryptoId = ownedCryptoId
        self.messageIdentifierFromEngine = messageIdentifierFromEngine
        self.attachmentNumber = attachmentNumber
        self.resumeOrPause = resumeOrPause
        super.init()
    }

    override func main(obvContext: ObvContext, viewContext: NSManagedObjectContext) {
        
        do {
            
            guard let message = try PersistedMessageReceived.get(messageIdentifierFromEngine: messageIdentifierFromEngine,
                                                                 ownedCryptoId: ownedCryptoId,
                                                                 within: obvContext.context)
            else {
                return
            }
            
            guard let join = message.fyleMessageJoinWithStatuses.first(where: { $0.index == attachmentNumber }) else {
                assertionFailure()
                return
            }
            
            switch resumeOrPause {
            case .resume:
                join.tryToSetStatusToDownloading()
            case .pause:
                join.tryToSetStatusToDownloadable()
            }
            
        } catch(let error) {
            assertionFailure()
            return cancel(withReason: .coreDataError(error: error))
        }
        
    }
}
