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
import os.log
import ObvCrypto
import ObvTypes
import ObvEncoder
import ObvMetaManager
import OlvidUtils

public final class ObvServerDownloadMessagesAndListAttachmentsMethod: ObvServerDataMethod {
    
    private static let logger = Logger(subsystem: "io.olvid.server.interface.ObvServerMethod", category: "ObvServerDownloadMessagesAndListAttachmentsMethod")
    private static let log = OSLog(subsystem: "io.olvid.server.interface.ObvServerMethod", category: "ObvServerDownloadMessagesAndListAttachmentsMethod")
    
    public let pathComponent = "/downloadMessagesAndListAttachments"
    
    public var serverURL: URL { return _ownedIdentity.serverURL }
    
    private let _ownedIdentity: ObvCryptoIdentity
    public var ownedIdentity: ObvCryptoIdentity? { _ownedIdentity }
    private let sessionToken: Data
    private let currentDeviceUid: UID
    public let isActiveOwnedIdentityRequired = true
    public let flowId: FlowIdentifier
    private let serverTimestampOfLastMessageBeforeTruncation: Int // In milliseconds

    weak public var identityDelegate: ObvIdentityDelegate? = nil // Set later

    public init(ownedIdentity: ObvCryptoIdentity, currentDeviceUid: UID, sessionToken: Data, serverTimestampOfLastMessageBeforeTruncation: Int?, flowId: FlowIdentifier) {
        self.flowId = flowId
        self._ownedIdentity = ownedIdentity
        self.sessionToken = sessionToken
        self.currentDeviceUid = currentDeviceUid
        self.serverTimestampOfLastMessageBeforeTruncation = serverTimestampOfLastMessageBeforeTruncation ?? 0
    }
    
    private enum PossibleReturnRawStatus: UInt8 {
        case ok = 0x00
        case invalidSession = 0x04
        case deviceIsNotRegistered = 0x0b
        case listingTruncated = 0x17
        case generalError = 0xff
    }
    
    public enum PossibleReturnStatus {
        case ok(downloadTimestampFromServer: Date, messagesAndAttachmentsOnServer: [MessageAndAttachmentsOnServer])
        case invalidSession
        case deviceIsNotRegistered
        case listingTruncated(downloadTimestampFromServer: Date, messagesAndAttachmentsOnServer: [MessageAndAttachmentsOnServer], serverTimestampOfLastMessageBeforeTruncation: Int)
        case generalError
    }

    lazy public var dataToSend: Data? = {
        return [_ownedIdentity.getIdentity(), sessionToken, currentDeviceUid, serverTimestampOfLastMessageBeforeTruncation].obvEncode().rawData
    }()
    
    public struct MessageAndAttachmentsOnServer {
        public let messageUidFromServer: UID
        public let messageUploadTimestampFromServer: Date
        fileprivate let messageUploadTimestampFromServerInMilliseconds: Int
        public let encryptedContent: EncryptedData
        public let hasEncryptedExtendedMessagePayload: Bool
        public let wrappedKey: EncryptedData
        public let attachments: [AttachmentOnServer]
    }
    
    public struct AttachmentOnServer {
        public let attachmentNumber: Int
        public let expectedLength: Int
        public let expectedChunkLength: Int
        public let chunkDownloadPrivateUrls: [URL?]
    }

    public static func parseObvServerResponse(responseData: Data, flowId: FlowIdentifier) -> PossibleReturnStatus? {
        
        guard let (rawServerReturnedStatus, listOfReturnedDatas) = genericParseObvServerResponse(responseData: responseData, using: log) else {
            os_log("Could not parse the server response", log: log, type: .error)
            assertionFailure()
            return nil
        }
        
        guard let serverReturnedStatus = PossibleReturnRawStatus(rawValue: rawServerReturnedStatus) else {
            os_log("The returned server status is invalid", log: log, type: .error)
            return nil
        }
        
        switch serverReturnedStatus {
            
        case .ok, .listingTruncated:
            guard listOfReturnedDatas.count >= 1 else {
                os_log("We could not decode the messages/attachments returned by the server: unexpected number of values", log: log, type: .error)
                return nil
            }
            let encodedDownloadTimestampFromServer = listOfReturnedDatas[0]
            let listOfReturnedMessageAndAttachmentsData = [ObvEncoded](listOfReturnedDatas[1...])
            guard let downloadTimestampFromServerInMilliseconds = Int(encodedDownloadTimestampFromServer) else {
                os_log("We could decode the timestamp returned by the server", log: log, type: .error)
                return nil
            }
            let downloadTimestampFromServer = Date(timeIntervalSince1970: Double(downloadTimestampFromServerInMilliseconds)/1000.0)
            let listOfUnparsedMessagesAndTheirAttachments = listOfReturnedMessageAndAttachmentsData.compactMap({ [ObvEncoded]($0) })
            guard listOfReturnedMessageAndAttachmentsData.count == listOfUnparsedMessagesAndTheirAttachments.count else {
                os_log("We could not decode the messages/attachments returned by the server", log: log, type: .error)
                return nil
            }
            let listOfMessageAndAttachments = listOfUnparsedMessagesAndTheirAttachments.compactMap({ ObvServerDownloadMessagesAndListAttachmentsMethod.parse(unparsedMessageAndAttachments: $0) })
            guard listOfMessageAndAttachments.count == listOfUnparsedMessagesAndTheirAttachments.count else {
                os_log("We could not decode the messages/attachments returned by the server", log: log, type: .error)
                return nil
            }
            os_log("[%{public}@] We succesfully parsed the message(s) and attachment(s)", log: log, type: .debug, flowId.shortDebugDescription)
            if serverReturnedStatus == .ok {
                return .ok(downloadTimestampFromServer: downloadTimestampFromServer, messagesAndAttachmentsOnServer: listOfMessageAndAttachments)
            } else if serverReturnedStatus == .listingTruncated {
                let serverTimestampOfLastMessageBeforeTruncation = listOfMessageAndAttachments.map(\.messageUploadTimestampFromServerInMilliseconds).max()
                assert(serverTimestampOfLastMessageBeforeTruncation != nil)
                return .listingTruncated(downloadTimestampFromServer: downloadTimestampFromServer, messagesAndAttachmentsOnServer: listOfMessageAndAttachments, serverTimestampOfLastMessageBeforeTruncation: serverTimestampOfLastMessageBeforeTruncation ?? 0)
            } else {
                assertionFailure()
                return nil
            }
            
        case .invalidSession:
            os_log("The server reported that the session is invalid", log: log, type: .error)
            return .invalidSession
            
        case .deviceIsNotRegistered:
            os_log("The server reported that the device is not registered", log: log, type: .error)
            return .deviceIsNotRegistered

        case .generalError:
            os_log("The server reported a general error", log: log, type: .error)
            return .generalError
            
        }
    }
    
    public static func parse(unparsedMessageAndAttachments: [ObvEncoded]) -> MessageAndAttachmentsOnServer? {

        // We expect the unparsedMessageAndAttachments list to contain encoded values of the following elements:
        // - the message uid,
        // - the header (containing our device uid, that we discard, and the wrapped key), and
        // - the encrypted content of the message.
        // - a Boolean indicating whether the APNS notification sent by the server did include mutable-content: 1
        // Each of the following elements (if any) represents an attachment

        guard unparsedMessageAndAttachments.count >= 4 else { assertionFailure(); return nil }

        // Parse the message uid, header, and encrypted content
        guard let messageId = UID(unparsedMessageAndAttachments[0]) else { assertionFailure(); return nil }
        guard let messageUploadTimestampFromServerInMilliseconds = Int(unparsedMessageAndAttachments[1]) else { assertionFailure(); return nil }
        let messageUploadTimestampFromServer = Date(timeIntervalSince1970: Double(messageUploadTimestampFromServerInMilliseconds)/1000.0)
        guard let wrappedKey = EncryptedData(unparsedMessageAndAttachments[2]) else { assertionFailure(); return nil }
        guard let encryptedContent = EncryptedData(unparsedMessageAndAttachments[3]) else { assertionFailure(); return nil }

        if unparsedMessageAndAttachments.count >= 5 {
            
            guard let hasEncryptedExtendedMessagePayload = Bool(unparsedMessageAndAttachments[4]) else { assertionFailure(); return nil }
            // Parse the attachments
            let rangeForAttachments = unparsedMessageAndAttachments.startIndex+5..<unparsedMessageAndAttachments.endIndex
            let unparsedAttachments = unparsedMessageAndAttachments[rangeForAttachments].compactMap({ [ObvEncoded]($0) })
            guard unparsedAttachments.count == unparsedMessageAndAttachments[rangeForAttachments].count else { assertionFailure(); return nil }
            let attachments = unparsedAttachments.compactMap({ parse(unparsedAttachment: $0) })
            guard attachments.count == unparsedAttachments.count else { assertionFailure(); return nil }
            let messageAndAttachmentsOnServer = MessageAndAttachmentsOnServer(messageUidFromServer: messageId,
                                                                              messageUploadTimestampFromServer: messageUploadTimestampFromServer,
                                                                              messageUploadTimestampFromServerInMilliseconds: messageUploadTimestampFromServerInMilliseconds,
                                                                              encryptedContent: encryptedContent,
                                                                              hasEncryptedExtendedMessagePayload: hasEncryptedExtendedMessagePayload,
                                                                              wrappedKey: wrappedKey,
                                                                              attachments: attachments)
            return messageAndAttachmentsOnServer

        } else {
            
            // This typically happens when receiving a message on the WebSocket
            
            let messageAndAttachmentsOnServer = MessageAndAttachmentsOnServer(messageUidFromServer: messageId,
                                                                              messageUploadTimestampFromServer: messageUploadTimestampFromServer,
                                                                              messageUploadTimestampFromServerInMilliseconds: messageUploadTimestampFromServerInMilliseconds,
                                                                              encryptedContent: encryptedContent,
                                                                              hasEncryptedExtendedMessagePayload: false,
                                                                              wrappedKey: wrappedKey,
                                                                              attachments: [])
            return messageAndAttachmentsOnServer
            
        }
    }

    
    private static func parse(unparsedAttachment: [ObvEncoded]) -> AttachmentOnServer? {
        // We expect the unparsedAttachment list to contain encoded values of the following elements:
        // - the attachment number
        // - the expected length of the attachment
        // - the expected chunk size
        // - one signed URL per chunk to download
        guard unparsedAttachment.count == 4 else { return nil }
        guard let attachmentNumber = Int(unparsedAttachment[0]) else { return nil }
        guard let expectedLength = Int(unparsedAttachment[1]) else { return nil }
        guard let expectedChunkSize = Int(unparsedAttachment[2]) else { return nil }
        guard let encodedURLs = [ObvEncoded](unparsedAttachment[3]) else { return nil }
        let chunkDownloadPrivateUrls: [URL?] = encodedURLs.map {
            guard let urlAsString = String($0) else { return nil }
            guard !urlAsString.isEmpty else { return nil }
            return URL(string: urlAsString)
        }
        let attachmentOnServer = AttachmentOnServer(attachmentNumber: attachmentNumber, expectedLength: expectedLength, expectedChunkLength: expectedChunkSize, chunkDownloadPrivateUrls: chunkDownloadPrivateUrls)
        return attachmentOnServer
    }

}
