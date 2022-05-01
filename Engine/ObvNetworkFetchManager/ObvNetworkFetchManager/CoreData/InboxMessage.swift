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
import CoreData
import os.log
import ObvMetaManager
import ObvCrypto
import ObvTypes
import OlvidUtils
import ObvEncoder

@objc(InboxMessage)
final class InboxMessage: NSManagedObject, ObvManagedObject, ObvErrorMaker {
    
    enum InternalError: Error {
        case aMessageWithTheSameMessageIdAlreadyExists
        case tryingToInsertAMessageThatWasAlreadyDeleted
        
        var localizedDescription: String {
            switch self {
            case .aMessageWithTheSameMessageIdAlreadyExists:
                return "A message with the same messageId already exists in DB"
            case .tryingToInsertAMessageThatWasAlreadyDeleted:
                return "Trying to insert a message in DB with a messageId that is identical to the one of a message that was recently deleted"
            }
        }
    }

    // MARK: Internal constants
    
    private static let entityName = "InboxMessage"
    private static let log = OSLog(subsystem: ObvNetworkFetchDelegateManager.defaultLogSubsystem, category: "InboxMessage")
    static var errorDomain = "InboxMessage"


    // MARK: Attributes
    
    @NSManaged private(set) var downloadTimestampFromServer: Date
    @NSManaged private(set) var encryptedContent: EncryptedData
    @NSManaged private(set) var extendedMessagePayload: Data?
    @NSManaged private(set) var fromCryptoIdentity: ObvCryptoIdentity? // Only set for application messages, at the same time than the attachments' infos
    @NSManaged private(set) var hasEncryptedExtendedMessagePayload: Bool
    @NSManaged private(set) var localDownloadTimestamp: Date
    @NSManaged private(set) var markedForDeletion: Bool // If true, a message will be deleted asap (i.e., when all its attachments are also marked for deletion)
    @NSManaged private(set) var messagePayload: Data? // Not set at download time, but at the same time than the attachments' infos
    @NSManaged private var rawMessageIdOwnedIdentity: Data
    @NSManaged private var rawMessageIdUid: Data
    @NSManaged private(set) var messageUploadTimestampFromServer: Date
    @NSManaged private var rawExtendedMessagePayloadKey: Data?
    @NSManaged private(set) var wrappedKey: EncryptedData
    
    // MARK: Relationships
    
    /// The var `dbAttachments` shall only be accessed through the `attachments`. The mechanism implemented here allows to make sure that an `InboxAttachment` instance accessed by means of an `InboxMessage` always has a non-nil `delegateManager`.
    @NSManaged private var dbAttachments: [InboxAttachment]?
    
    var attachments: [InboxAttachment] {
        get {
            let values = dbAttachments
            return values?.map { $0.obvContext = self.obvContext; return $0 } ?? []
        }
        set {
            dbAttachments = newValue
        }
    }
    
    var attachmentIds: [AttachmentIdentifier] {
        return attachments.map { $0.attachmentId }
    }

    // MARK: Other variables
    
    private(set) var extendedMessagePayloadKey: AuthenticatedEncryptionKey? {
        get {
            guard let rawEncoded = rawExtendedMessagePayloadKey else { return nil }
            guard let encodedKey = ObvEncoded(withRawData: rawEncoded) else { assertionFailure(); return nil }
            guard let key = try? AuthenticatedEncryptionKeyDecoder.decode(encodedKey) else { assertionFailure(); return nil }
            return key
        }
        set {
            self.rawExtendedMessagePayloadKey = newValue?.encode().rawData
        }
    }
    
    private(set) var messageId: MessageIdentifier {
        get { return MessageIdentifier(rawOwnedCryptoIdentity: self.rawMessageIdOwnedIdentity, rawUid: self.rawMessageIdUid)! }
        set { self.rawMessageIdOwnedIdentity = newValue.ownedCryptoIdentity.getIdentity(); self.rawMessageIdUid = newValue.uid.raw }
    }
    
    var obvContext: ObvContext?
    
    var canBeDeleted: Bool {
        guard markedForDeletion else {
            return false
        }
        for attachment in attachments {
            guard attachment.markedForDeletion else {
                return false
            }
        }
        return true
    }
    
    func getAttachmentDirectory(withinInbox inbox: URL) -> URL {
        let sha256 = ObvCryptoSuite.sharedInstance.hashFunctionSha256()
        let directoryName = sha256.hash(messageId.rawValue).hexString()
        return inbox.appendingPathComponent(directoryName, isDirectory: true)
    }
    
    // MARK: - Initializer
    
    convenience init(messageId: MessageIdentifier, toIdentity: ObvCryptoIdentity, encryptedContent: EncryptedData, hasEncryptedExtendedMessagePayload: Bool, wrappedKey: EncryptedData, messageUploadTimestampFromServer: Date, downloadTimestampFromServer: Date, localDownloadTimestamp: Date, within obvContext: ObvContext) throws {
        
        os_log("🔑 Creating InboxMessage with id %{public}@", log: Self.log, type: .info, messageId.debugDescription)
        
        guard try InboxMessage.get(messageId: messageId, within: obvContext) == nil else {
            throw InternalError.aMessageWithTheSameMessageIdAlreadyExists
        }
        let entityDescription = NSEntityDescription.entity(forEntityName: InboxMessage.entityName, in: obvContext)!
        self.init(entity: entityDescription, insertInto: obvContext)
        
        self.encryptedContent = encryptedContent
        self.extendedMessagePayload = nil
        self.fromCryptoIdentity = nil
        self.hasEncryptedExtendedMessagePayload = hasEncryptedExtendedMessagePayload
        self.localDownloadTimestamp = localDownloadTimestamp
        self.messageId = messageId
        self.messageUploadTimestampFromServer = messageUploadTimestampFromServer
        self.rawExtendedMessagePayloadKey = nil
        self.downloadTimestampFromServer = downloadTimestampFromServer
        self.wrappedKey = wrappedKey
        
    }

}


// MARK: - Utility methods

extension InboxMessage {
        
    func createAttachmentsDirectoryIfRequired(withinInbox inbox: URL) throws {
        let attachmentsDirectory = getAttachmentDirectory(withinInbox: inbox)
        guard !FileManager.default.fileExists(atPath: attachmentsDirectory.path) else { return }
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: false)
    }
    
    func deleteAttachmentsDirectory(fromInbox inbox: URL) throws {
        let attachmentsDirectory = getAttachmentDirectory(withinInbox: inbox)
        guard FileManager.default.fileExists(atPath: attachmentsDirectory.path) else { return }
        try FileManager.default.removeItem(at: attachmentsDirectory)
    }
    
    func set(fromCryptoIdentity: ObvCryptoIdentity, andMessagePayload messagePayload: Data, extendedMessagePayloadKey: AuthenticatedEncryptionKey?, flowId: FlowIdentifier, delegateManager: ObvNetworkFetchDelegateManager) throws {
        os_log("🔑 Setting fromCryptoIdentity and messagePayload of message %{public}@", log: Self.log, type: .info, messageId.debugDescription)
        if self.fromCryptoIdentity == nil {
           self.fromCryptoIdentity = fromCryptoIdentity
        } else {
            guard self.fromCryptoIdentity == fromCryptoIdentity else {
                assertionFailure()
                throw Self.makeError(message: "Incoherent from identity")
            }
        }
        if self.messagePayload == nil {
            self.messagePayload = messagePayload
        } else {
            guard self.messagePayload == messagePayload else {
                assertionFailure()
                throw Self.makeError(message: "Incoherent message payload")
            }
        }
        self.extendedMessagePayloadKey = extendedMessagePayloadKey
        let messageId = self.messageId
        let attachmentIds = self.attachmentIds
        let hasEncryptedExtendedMessagePayload = self.hasEncryptedExtendedMessagePayload && (extendedMessagePayloadKey != nil)
        try obvContext?.addContextDidSaveCompletionHandler({ (error) in
            guard error == nil else { return }
            delegateManager.networkFetchFlowDelegate.messagePayloadAndFromIdentityWereSet(messageId: messageId, attachmentIds: attachmentIds, hasEncryptedExtendedMessagePayload: hasEncryptedExtendedMessagePayload, flowId: flowId)
        })
    }
    
    var isProcessed: Bool { self.fromCryptoIdentity != nil && self.messagePayload != nil }
    
    // MARK: - Setters
    
    func markForDeletion() {
        markedForDeletion = true
    }
    
    var receivedByteCount: Int {
        return encryptedContent.count
    }
    
    func setExtendedMessagePayload(to data: Data) {
        self.extendedMessagePayload = data
    }
    
    func deleteExtendedMessagePayload() {
        assert(extendedMessagePayload == nil)
        assert(hasEncryptedExtendedMessagePayload)
        assert(extendedMessagePayloadKey != nil)
        extendedMessagePayload = nil
        hasEncryptedExtendedMessagePayload = false
        extendedMessagePayloadKey = nil
    }
}


// MARK: - Convenience DB getters

extension InboxMessage {
    
    @nonobjc class func fetchRequest() -> NSFetchRequest<InboxMessage> {
        return NSFetchRequest<InboxMessage>(entityName: InboxMessage.entityName)
    }
    
    
    struct Predicate {
        enum Key: String {
            case encryptedContentKey = "encryptedContent"
            case fromCryptoIdentityKey = "fromCryptoIdentity"
            case messagePayloadKey = "messagePayload"
            case rawMessageIdOwnedIdentityKey = "rawMessageIdOwnedIdentity"
            case rawMessageIdUidKey = "rawMessageIdUid"
        }
        static func withMessageIdOwnedCryptoId(_ ownedCryptoId: ObvCryptoIdentity) -> NSPredicate {
            NSPredicate(Key.rawMessageIdOwnedIdentityKey, EqualToData: ownedCryptoId.getIdentity())
        }
        static func withMessageIdUid(_ uid: UID) -> NSPredicate {
            NSPredicate(Key.rawMessageIdUidKey, EqualToData: uid.raw)
        }
        static func withMessageIdentifier(_ messageId: MessageIdentifier) -> NSPredicate {
            NSCompoundPredicate(andPredicateWithSubpredicates: [
                withMessageIdOwnedCryptoId(messageId.ownedCryptoIdentity),
                withMessageIdUid(messageId.uid),
            ])
        }
        static var isUnprocessed: NSPredicate {
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(withNilValueForKey: Key.fromCryptoIdentityKey),
                NSPredicate(withNilValueForKey: Key.messagePayloadKey),
            ])
        }
    }
    
    
    static func getAll(forIdentity cryptoIdentity: ObvCryptoIdentity? = nil, within obvContext: ObvContext) throws -> [InboxMessage] {
        let request: NSFetchRequest<InboxMessage> = InboxMessage.fetchRequest()
        if let cryptoIdentity = cryptoIdentity {
            request.predicate = Predicate.withMessageIdOwnedCryptoId(cryptoIdentity)
        }
        return try obvContext.fetch(request)
    }
    
    
    static func getAllUnprocessedMessages(within obvContext: ObvContext) throws -> [InboxMessage] {
        let request: NSFetchRequest<InboxMessage> = InboxMessage.fetchRequest()
        request.predicate = Predicate.isUnprocessed
        return try obvContext.fetch(request)
    }
    
    
    static func get(messageId: MessageIdentifier, within obvContext: ObvContext) throws -> InboxMessage? {
        let request: NSFetchRequest<InboxMessage> = InboxMessage.fetchRequest()
        request.predicate = Predicate.withMessageIdentifier(messageId)
        request.fetchLimit = 1
        return (try obvContext.fetch(request)).first
    }

}
