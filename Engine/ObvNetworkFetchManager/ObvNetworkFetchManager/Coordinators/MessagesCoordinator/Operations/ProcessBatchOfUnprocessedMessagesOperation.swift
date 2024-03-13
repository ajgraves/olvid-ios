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
import OlvidUtils
import ObvMetaManager
import os.log
import ObvCrypto
import CoreData
import ObvTypes


final class ProcessBatchOfUnprocessedMessagesOperation: ContextualOperationWithSpecificReasonForCancel<CoreDataOperationReasonForCancel> {
    
    private static let batchSize = 10
    
    private let ownedCryptoIdentity: ObvCryptoIdentity
    private let debugUuid = UUID()
    private let queueForPostingNotifications: DispatchQueue
    private let notificationDelegate: ObvNotificationDelegate
    private let processDownloadedMessageDelegate: ObvProcessDownloadedMessageDelegate
    private let inbox: URL // For attachments
    private let log: OSLog
    
    /// After the execution of this operation, we will have other tasks to perform.
    enum PostOperationTaskToPerform {
        case processInboxAttachmentsOfMessage(messageId: ObvMessageIdentifier)
        case downloadExtendedPayload(messageId: ObvMessageIdentifier)
        case notifyAboutDecryptedApplicationMessage(messageId: ObvMessageIdentifier, attachmentIds: [ObvAttachmentIdentifier], hasEncryptedExtendedMessagePayload: Bool, flowId: FlowIdentifier)
        case markMessageAsListedOnServer(messageId: ObvMessageIdentifier)
        case processPendingDeleteFromServer(messageId: ObvMessageIdentifier)
    }
    
    private(set) var postOperationTasksToPerform = [PostOperationTaskToPerform]()
    private(set) var moreUnprocessedMessagesRemain: Bool? // If the operation finishes without canceling, this is guaranteed to be set
    
    init(ownedCryptoIdentity: ObvCryptoIdentity, queueForPostingNotifications: DispatchQueue, notificationDelegate: ObvNotificationDelegate, processDownloadedMessageDelegate: ObvProcessDownloadedMessageDelegate, inbox: URL, log: OSLog) {
        self.ownedCryptoIdentity = ownedCryptoIdentity
        self.queueForPostingNotifications = queueForPostingNotifications
        self.notificationDelegate = notificationDelegate
        self.processDownloadedMessageDelegate = processDownloadedMessageDelegate
        self.inbox = inbox
        self.log = log
        super.init()
    }
    
    
    override func main(obvContext: ObvContext, viewContext: NSManagedObjectContext) {
        
        os_log("🔑 Starting ProcessAllUnprocessedMessagesOperation %{public}@", log: log, type: .info, debugUuid.debugDescription)
        defer {
            if !isCancelled && moreUnprocessedMessagesRemain == nil {
                assertionFailure()
            }
            os_log("🔑 Ending ProcessAllUnprocessedMessagesOperation %{public}@", log: log, type: .info, debugUuid.debugDescription)
        }
                
        do {
            
            // Find all inbox messages that still need to be processed
            
            let messages = try InboxMessage.getBatchOfUnprocessedMessages(ownedCryptoIdentity: ownedCryptoIdentity, batchSize: Self.batchSize, within: obvContext)
            
            guard !messages.isEmpty else {
                moreUnprocessedMessagesRemain = false
                return
            }
            
            moreUnprocessedMessagesRemain = true
            
            for message in messages {
                os_log("🔑 Will process message %{public}@", log: log, type: .info, message.messageId.debugDescription)
                assert(message.extendedMessagePayloadKey == nil)
                assert(message.messagePayload == nil)
                assert(!message.markedForDeletion)
            }
            
            // We then create the appropriate struct that is appropriate to pass each message to our delegate (i.e., the channel manager).
            
            let networkReceivedEncryptedMessages: [ObvNetworkReceivedMessageEncrypted] = messages.compactMap {
                guard let inboxMessageId = $0.messageId else { assertionFailure(); return nil }
                return ObvNetworkReceivedMessageEncrypted(
                    messageId: inboxMessageId,
                    messageUploadTimestampFromServer: $0.messageUploadTimestampFromServer,
                    downloadTimestampFromServer: $0.downloadTimestampFromServer,
                    localDownloadTimestamp: $0.localDownloadTimestamp,
                    encryptedContent: $0.encryptedContent,
                    wrappedKey: $0.wrappedKey,
                    knownAttachmentCount: $0.attachments.count,
                    availableEncryptedExtendedContent: nil) // The encrypted extended content is not available yet
            }
            
            // We ask our delegate to process these messages
            
            let results = try processDownloadedMessageDelegate.processNetworkReceivedEncryptedMessages(Set(networkReceivedEncryptedMessages), within: obvContext)
            
            assert(results.count == networkReceivedEncryptedMessages.count)
            
            // Update this network manager's databases depending on the result for each message.
            // Note that this allows to have to have atomicity between the changes made in the channel manager and the changes made here
            
            for result in results {
                switch result {
                    
                case .protocolMessageWasProcessed(let messageId),
                        .noKeyAllowedToDecrypt(let messageId),
                        .couldNotDecryptOrParse(let messageId),
                        .protocolManagerFailedToProcessMessage(let messageId),
                        .protocolMessageCouldNotBeParsed(let messageId),
                        .invalidAttachmentCountOfApplicationMessage(let messageId),
                        .applicationMessageCouldNotBeParsed(let messageId),
                        .unexpectedMessageType(let messageId):
                    
                    try InboxMessage.markMessageAndAttachmentsForDeletionAndCreatePendingDeleteFromServer(messageId: messageId, within: obvContext)
                    postOperationTasksToPerform.append(.processPendingDeleteFromServer(messageId: messageId))

                case .remoteIdentityToSetOnReceivedMessage(let messageId, let remoteCryptoIdentity, let messagePayload, let extendedMessagePayloadKey, let attachmentsInfos):
                    
                    guard let inboxMessage = try InboxMessage.get(messageId: messageId, within: obvContext) else {
                        assertionFailure()
                        continue
                    }
                    
                    guard inboxMessage.attachments.count == attachmentsInfos.count else {
                        assertionFailure()
                        try InboxMessage.markMessageAndAttachmentsForDeletionAndCreatePendingDeleteFromServer (messageId: messageId, within: obvContext)
                        postOperationTasksToPerform.append(.processPendingDeleteFromServer(messageId: messageId))
                        continue
                    }
                    
                    // If the message has attachments, we want to mark it as "listed" on the server, to make sure it won't be listed again.
                    // If it does not have any attachment, we will soon delete it, so that there is no need to mark it as "listed".
                    let messageCanBeMarkedAsListedOnServer = !attachmentsInfos.isEmpty
                    try inboxMessage.setFromCryptoIdentity(remoteCryptoIdentity,
                                                           andMessagePayload: messagePayload,
                                                           extendedMessagePayloadKey: extendedMessagePayloadKey)
                    
                    for inboxMessageAttachment in inboxMessage.attachments {
                        guard inboxMessageAttachment.attachmentNumber >= 0 && inboxMessageAttachment.attachmentNumber < attachmentsInfos.count else {
                            assertionFailure()
                            continue
                        }
                        let attachmentInfos = attachmentsInfos[inboxMessageAttachment.attachmentNumber]
                        try inboxMessageAttachment.set(decryptionKey: attachmentInfos.key,
                                                       metadata: attachmentInfos.metadata,
                                                       inbox: inbox)
                    }
                    
                    // Compute all the appropriate `PostOperationTaskToPerform`s to perform
                    
                    do {
                        let hasEncryptedExtendedMessagePayload = inboxMessage.hasEncryptedExtendedMessagePayload && (extendedMessagePayloadKey != nil)
                        postOperationTasksToPerform.append(.notifyAboutDecryptedApplicationMessage(
                            messageId: messageId,
                            attachmentIds: inboxMessage.attachmentIds,
                            hasEncryptedExtendedMessagePayload: hasEncryptedExtendedMessagePayload,
                            flowId: obvContext.flowId))
                    }
                    
                    if messageCanBeMarkedAsListedOnServer {
                        postOperationTasksToPerform.append(.markMessageAsListedOnServer(messageId: messageId))
                    }
                    
                    // We have set all the elements allowing the attachments to be downloaded.
                    // So we process all the attachment in case the context saves successfully
                    
                    if !inboxMessage.attachments.isEmpty {
                        postOperationTasksToPerform.append(.processInboxAttachmentsOfMessage(messageId: messageId))
                    }
                                        
                    // If the message has an encrypted payload to download, we ask for the download
                    if inboxMessage.hasEncryptedExtendedMessagePayload && extendedMessagePayloadKey != nil {
                        postOperationTasksToPerform.append(.downloadExtendedPayload(messageId: messageId))
                    }

                }
            }
            
        } catch {
            return cancel(withReason: .coreDataError(error: error))
        }
        
    }
    
}
