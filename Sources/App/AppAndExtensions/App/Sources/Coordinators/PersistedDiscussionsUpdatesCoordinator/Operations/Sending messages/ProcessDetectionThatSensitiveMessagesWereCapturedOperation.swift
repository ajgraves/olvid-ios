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
import OlvidUtils
import ObvEngine
import ObvTypes
import ObvUICoreData
import os.log
import CoreData


/// This operation allows to process a received message indicating that one of our contacts did take a screen capture of some sensitive (read-once of with limited visibility) messages within a discussion. If this happen, we want to show this to the owned identity by displaying an appropriate system message within the corresponding discussion.
final class ProcessDetectionThatSensitiveMessagesWereCapturedOperation: ContextualOperationWithSpecificReasonForCancel<ProcessDetectionThatSensitiveMessagesWereCapturedOperation.ReasonForCancel>, @unchecked Sendable {
    
    enum Requester {
        case contact(contactIdentifier: ObvContactIdentifier)
        case ownedIdentity(ownedCryptoId: ObvCryptoId)
    }

    let screenCaptureDetectionJSON: ScreenCaptureDetectionJSON
    private let requester: Requester
    private let messageUploadTimestampFromServer: Date

    
    init(screenCaptureDetectionJSON: ScreenCaptureDetectionJSON, requester: Requester, messageUploadTimestampFromServer: Date) {
        self.screenCaptureDetectionJSON = screenCaptureDetectionJSON
        self.requester = requester
        self.messageUploadTimestampFromServer = messageUploadTimestampFromServer
        super.init()
    }

    
    enum Result {
        case couldNotFindGroupV2InDatabase(groupIdentifier: GroupV2Identifier)
        case processed
    }

    private(set) var result: Result?

    
    override func main(obvContext: ObvContext, viewContext: NSManagedObjectContext) {
        
        do {
            
            switch requester {
                
            case .contact(contactIdentifier: let contactIdentifier):
                
                guard let contact = try PersistedObvContactIdentity.get(persisted: contactIdentifier, whereOneToOneStatusIs: .any, within: obvContext.context) else {
                    return cancel(withReason: .couldNotFindContact)
                }
                
                try contact.processDetectionThatSensitiveMessagesWereCapturedByThisContact(screenCaptureDetectionJSON: screenCaptureDetectionJSON, messageUploadTimestampFromServer: messageUploadTimestampFromServer)
                
                
            case .ownedIdentity(ownedCryptoId: let ownedCryptoId):
                
                guard let ownedIdentity = try PersistedObvOwnedIdentity.get(cryptoId: ownedCryptoId, within: obvContext.context) else {
                    return cancel(withReason: .couldNotFindOwnedIdentity)
                }
                
                try ownedIdentity.processDetectionThatSensitiveMessagesWereCapturedByThisOwnedIdentity(screenCaptureDetectionJSON: screenCaptureDetectionJSON, messageUploadTimestampFromServer: messageUploadTimestampFromServer)
                
            }
            
            result = .processed
            
        } catch {
            if let error = error as? ObvUICoreDataError {
                switch error {
                case .couldNotFindGroupV2InDatabase(groupIdentifier: let groupIdentifier):
                    result = .couldNotFindGroupV2InDatabase(groupIdentifier: groupIdentifier)
                    return
                default:
                    assertionFailure()
                    return cancel(withReason: .coreDataError(error: error))
                }
            } else {
                assertionFailure()
                return cancel(withReason: .coreDataError(error: error))
            }
        }
        
    }
    
    
    enum ReasonForCancel: LocalizedErrorWithLogType {

        case coreDataError(error: Error)
        case contextIsNil
        case couldNotFindOwnedIdentity
        case couldNotFindContact
        
        var logType: OSLogType {
            switch self {
            case .coreDataError,
                    .contextIsNil,
                    .couldNotFindOwnedIdentity,
                    .couldNotFindContact:
                return .fault
            }
        }
        
        var errorDescription: String? {
            switch self {
            case .contextIsNil:
                return "Context is nil"
            case .coreDataError(error: let error):
                return "Core Data error: \(error.localizedDescription)"
            case .couldNotFindOwnedIdentity:
                return "Could not find owned identity"
            case .couldNotFindContact:
                return "Could not find contact"
            }
        }
        
    }

}
