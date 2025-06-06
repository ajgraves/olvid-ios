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
import ObvTypes
import ObvMetaManager
import ObvCrypto
import OlvidUtils


// MARK: - Protocol Steps

extension DownloadIdentityPhotoChildProtocol {
    
    enum StepId: Int, ConcreteProtocolStepId, CaseIterable {
        
        case queryServer = 0
        case downloadingPhoto = 1

        func getConcreteProtocolStep(_ concreteProtocol: ConcreteCryptoProtocol, _ receivedMessage: ConcreteProtocolMessage) -> ConcreteProtocolStep? {
            
            switch self {
                
            case .queryServer:
                let step = QueryServerStep(from: concreteProtocol, and: receivedMessage)
                return step
            case .downloadingPhoto:
                let step = ProcessPhotoStep(from: concreteProtocol, and: receivedMessage)
                return step
            }
        }
    }
    
    
    // MARK: - QueryServerStep
    
    final class QueryServerStep: ProtocolStep, TypedConcreteProtocolStep {
        
        let startState: ConcreteProtocolInitialState
        let receivedMessage: InitialMessage
        
        init?(startState: ConcreteProtocolInitialState, receivedMessage: DownloadIdentityPhotoChildProtocol.InitialMessage, concreteCryptoProtocol: ConcreteCryptoProtocol) {
            
            self.startState = startState
            self.receivedMessage = receivedMessage
            
            super.init(expectedToIdentity: concreteCryptoProtocol.ownedIdentity,
                       expectedReceptionChannelInfo: .local,
                       receivedMessage: receivedMessage,
                       concreteCryptoProtocol: concreteCryptoProtocol)
        }
        
        override func executeStep(within obvContext: ObvContext) throws -> ConcreteProtocolState? {

            let log = OSLog(subsystem: delegateManager.logSubsystem, category: DownloadIdentityPhotoChildProtocol.logCategory)

            guard let label = receivedMessage.contactIdentityDetailsElements.photoServerKeyAndLabel?.label else {
                os_log("The server label is not set", log: log, type: .fault)
                return nil
            }
            
            // Get the encrypted photo

            let coreMessage = getCoreMessage(for: ObvChannelSendChannelType.serverQuery(ownedIdentity: ownedIdentity))
            let concreteMessage = ServerGetPhotoMessage(coreProtocolMessage: coreMessage)
            let serverQueryType = ObvChannelServerQueryMessageToSend.QueryType.getUserData(of: receivedMessage.contactIdentity, label: label)
            guard let messageToSend = concreteMessage.generateObvChannelServerQueryMessageToSend(serverQueryType: serverQueryType) else { return nil }
            _ = try channelDelegate.postChannelMessage(messageToSend, randomizedWith: prng, within: obvContext)

            return DownloadingPhotoState(contactIdentity: receivedMessage.contactIdentity, contactIdentityDetailsElements: receivedMessage.contactIdentityDetailsElements)
        }
        
    }
    
    
    // MARK: - DownloadingPhotoStep
    
    final class ProcessPhotoStep: ProtocolStep, TypedConcreteProtocolStep {
        
        let startState: DownloadingPhotoState
        let receivedMessage: ServerGetPhotoMessage
        
        init?(startState: DownloadingPhotoState, receivedMessage: DownloadIdentityPhotoChildProtocol.ServerGetPhotoMessage, concreteCryptoProtocol: ConcreteCryptoProtocol) {
            
            self.startState = startState
            self.receivedMessage = receivedMessage
            
            super.init(expectedToIdentity: concreteCryptoProtocol.ownedIdentity,
                       expectedReceptionChannelInfo: .local,
                       receivedMessage: receivedMessage,
                       concreteCryptoProtocol: concreteCryptoProtocol)
        }
        
        override func executeStep(within obvContext: ObvContext) throws -> ConcreteProtocolState? {
            
            let log = OSLog(subsystem: delegateManager.logSubsystem, category: DownloadIdentityPhotoChildProtocol.logCategory)

            guard let encryptedPhotoData = receivedMessage.encryptedPhoto else {
                // Photo was deleted from the server
                return PhotoDownloadedState()
            }

            let identityDetailsElements = startState.contactIdentityDetailsElements
            guard let photoServerKeyAndLabel = identityDetailsElements.photoServerKeyAndLabel else {
                os_log("Could not get photo label and key", log: log, type: .fault)
                return CancelledState()
            }

            let authEnc = ObvCryptoSuite.sharedInstance.authenticatedEncryption()

            guard let photo = try? authEnc.decrypt(encryptedPhotoData, with: photoServerKeyAndLabel.key) else {
                os_log("Could not decrypt the photo", log: log, type: .fault)
                return CancelledState()
            }

            // Check whether you downloaded your own photo or a contact photo
            if startState.contactIdentity == ownedIdentity {
                try identityDelegate.updateDownloadedPhotoOfOwnedIdentity(ownedIdentity, version: startState.contactIdentityDetailsElements.version, photo: photo, within: obvContext)
            } else {
                try identityDelegate.updateDownloadedPhotoOfContactIdentity(startState.contactIdentity, ofOwnedIdentity: ownedIdentity, version: startState.contactIdentityDetailsElements.version, photo: photo, within: obvContext)
            }

            let downloadedUserData = delegateManager.downloadedUserData
            if let photoFilenameToDelete = receivedMessage.photoFilenameToDelete {
                let url = downloadedUserData.appendingPathComponent(photoFilenameToDelete)
                try? FileManager.default.removeItem(at: url)
            }

            return PhotoDownloadedState()
        }
        
    }

}
