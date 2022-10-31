/*
 *  Olvid for iOS
 *  Copyright © 2019-2022 Olvid SAS
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
import os.log
import ObvTypes
import ObvCrypto
import ObvEngine

final class CreateRandomMessageReceivedDebugOperation: ContextualOperationWithSpecificReasonForCancel<CreateRandomMessageReceivedDebugOperationReasonForCancel> {

    private let discussionObjectID: TypeSafeManagedObjectID<PersistedDiscussion>
    
    init(discussionObjectID: TypeSafeManagedObjectID<PersistedDiscussion>) {
        self.discussionObjectID = discussionObjectID
        super.init()
    }

    override func main() {
        
        guard let obvContext = self.obvContext else {
            return cancel(withReason: .contextIsNil)
        }

        let prng = ObvCryptoSuite.sharedInstance.prngService()

        obvContext.performAndWait {
            
            do {
                guard let discussion = try PersistedDiscussion.get(objectID: discussionObjectID, within: obvContext.context) else {
                    return cancel(withReason: .couldNotFindDiscussion)
                }
                
                guard let persistedContactIdentity = chooseRandomContact(from: discussion) else {
                    return cancel(withReason: .internalError)
                }
                
                try? PersistedDiscussion.insertSystemMessagesIfDiscussionIsEmpty(discussionObjectID: discussion.objectID, markAsRead: true, within: obvContext.context)

                let randomBodySize = Int.random(in: Range<Int>.init(uncheckedBounds: (lower: 2, upper: 200)))
                let randomBody = CreateRandomMessageReceivedDebugOperation.randomString(length: randomBodySize)

                let messageJSON: MessageJSON
                
                switch try discussion.kind {
                case .oneToOne:
                    
                    messageJSON = MessageJSON(senderSequenceNumber: 0,
                                              senderThreadIdentifier: UUID(),
                                              body: randomBody,
                                              replyTo: nil,
                                              expiration: nil,
                                              forwarded: false)

                case .groupV1(withContactGroup: let contactGroup):
                    guard let contactGroup = contactGroup else {
                        return cancel(withReason: .internalError)
                    }
                    guard let groupOwner = try? ObvCryptoId(identity: contactGroup.ownerIdentity) else {
                        return cancel(withReason: .internalError)
                    }
                    let groupV1Identifier = (contactGroup.groupUid, groupOwner)
                    messageJSON = MessageJSON(senderSequenceNumber: 0,
                                              senderThreadIdentifier: UUID(),
                                              body: randomBody,
                                              groupV1Identifier: groupV1Identifier,
                                              replyTo: nil,
                                              expiration: nil,
                                              forwarded: false)
                    
                case .groupV2(withGroup: let group):
                    guard let groupV2Identifier = group?.groupIdentifier else {
                        return cancel(withReason: .internalError)
                    }
                    messageJSON = MessageJSON(senderSequenceNumber: 0,
                                              senderThreadIdentifier: UUID(),
                                              body: randomBody,
                                              groupV2Identifier: groupV2Identifier,
                                              replyTo: nil,
                                              expiration: nil,
                                              forwarded: false,
                                              originalServerTimestamp: nil)
                }
                
                
                let randomMessageIdentifierFromEngine = UID.gen(with: prng).raw

                guard (try? PersistedMessageReceived(messageUploadTimestampFromServer: Date(),
                                                     downloadTimestampFromServer: Date(),
                                                     localDownloadTimestamp: Date(),
                                                     messageJSON: messageJSON,
                                                     contactIdentity: persistedContactIdentity,
                                                     messageIdentifierFromEngine: randomMessageIdentifierFromEngine,
                                                     returnReceiptJSON: nil,
                                                     missedMessageCount: 0,
                                                     discussion: discussion,
                                                     obvMessageContainsAttachments: false)) != nil else {
                    return cancel(withReason: .internalError)
                }

            } catch {
                return cancel(withReason: .coreDataError(error: error))
            }

            
        }
        
    }
    
    private func chooseRandomContact(from discussion: PersistedDiscussion) -> PersistedObvContactIdentity? {
        switch try? discussion.kind {
        case .oneToOne(withContactIdentity: let contactIdentity):
            return contactIdentity
        case .groupV1(withContactGroup: let contactGroup):
            return contactGroup?.contactIdentities.randomElement()
        case .groupV2(withGroup: let group):
            return group?.contactsAmongNonPendingOtherMembers.randomElement()
        case .none:
            return nil
        }
    }
    
    
    static func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789                  "
        return String((0...length-1).map { _ in letters.randomElement()! })
    }

}


enum CreateRandomMessageReceivedDebugOperationReasonForCancel: LocalizedErrorWithLogType {

    case coreDataError(error: Error)
    case couldNotFindDiscussion
    case contextIsNil
    case internalError

    var logType: OSLogType {
        switch self {
        case .coreDataError,
             .contextIsNil,
             .internalError:
            return .fault
        case .couldNotFindDiscussion:
            return .error
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .internalError:
            return "Internal error"
        case .contextIsNil:
            return "Context is nil"
        case .coreDataError(error: let error):
            return "Core Data error: \(error.localizedDescription)"
        case .couldNotFindDiscussion:
            return "Could not find discussion in database"
        }
    }

    
}
