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
import ObvTypes
import ObvUICoreData
import ObvAppCoreConstants


final class SetTimestampMessageSentOfPersistedMessageSentRecipientInfosOperation: ContextualOperationWithSpecificReasonForCancel<CoreDataOperationReasonForCancel>, @unchecked Sendable {
 
    private let log = OSLog(subsystem: ObvAppCoreConstants.logSubsystem, category: String(describing: SetTimestampMessageSentOfPersistedMessageSentRecipientInfosOperation.self))

    private let ownedCryptoId: ObvCryptoId
    private let messageIdentifierFromEngineAndTimestampFromServer: [(messageIdentifierFromEngine: Data, timestampFromServer: Date)]
    private let alsoMarkAttachmentsAsSent: Bool
    
    init(ownedCryptoId: ObvCryptoId, messageIdentifierFromEngineAndTimestampFromServer: [(messageIdentifierFromEngine: Data, timestampFromServer: Date)], alsoMarkAttachmentsAsSent: Bool) {
        self.ownedCryptoId = ownedCryptoId
        self.messageIdentifierFromEngineAndTimestampFromServer = messageIdentifierFromEngineAndTimestampFromServer
        self.alsoMarkAttachmentsAsSent = alsoMarkAttachmentsAsSent
        super.init()
    }
    
    override func main(obvContext: ObvContext, viewContext: NSManagedObjectContext) {
        
        do {
            
            for (messageIdentifierFromEngine, timestampFromServer) in messageIdentifierFromEngineAndTimestampFromServer {
                
                let infos = try PersistedMessageSentRecipientInfos.getAllPersistedMessageSentRecipientInfosWithoutTimestampMessageSentAndMatching(
                    messageIdentifierFromEngine: messageIdentifierFromEngine,
                    ownedCryptoId: ownedCryptoId,
                    within: obvContext.context)
                
                // Note that the infos list may be empty for that messageIdentifierFromEngine and owned identity.
                // Since we now (2022-02-24) also filter out infos that already have a timestampMessageSent, this is not an issue.
                
                infos.forEach {
                    $0.messageWasSentNoLaterThan(timestampFromServer, alsoMarkAttachmentsAsSent: alsoMarkAttachmentsAsSent)
                }
                
            }
            
            
        } catch {
            return cancel(withReason: .coreDataError(error: error))
        }
        
    }

}
