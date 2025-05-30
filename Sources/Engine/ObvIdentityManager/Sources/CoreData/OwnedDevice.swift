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
import ObvMetaManager
import ObvCrypto
import ObvTypes
import OlvidUtils

@objc(OwnedDevice)
final class OwnedDevice: NSManagedObject, ObvManagedObject {

    private static let entityName = "OwnedDevice"
    private static func makeError(message: String) -> Error { NSError(domain: "OwnedDevice", code: 0, userInfo: [NSLocalizedFailureReasonErrorKey: message]) }

    
    // MARK: Attributes
    
    @NSManaged private var expirationDate: Date?
    @NSManaged private(set) var latestChannelCreationPingTimestamp: Date? // Always nil for the current device, may be non-nil for a remote owned device
    @NSManaged private var latestRegistrationDate: Date?
    @NSManaged private(set) var name: String?
    @NSManaged private var rawCapabilities: String?
    @NSManaged private(set) var uid: UID // Unique (not enforced)

    // MARK: Relationships
    
    @NSManaged private var preKeyForRemoteOwnedDevice: PreKeyForRemoteOwnedDevice? // Always nil for the current device, may be non-nil for a remote owned device. Set in the init of PreKeyForRemoteOwnedDevice
    @NSManaged private var preKeysForCurrentDevice: Set<PreKeyForCurrentOwnedDevice> // Always empty for a remote owned device. New elements are added by calling ``static createPreKeyForCurrentOwnedDevice(forCurrentOwnedDevice:withExpirationTimestamp:prng:)`` on ``PreKeyForCurrentOwnedDevice``
    
    /// If this device the current device of an owned identity, then currentDeviceIdentity is not nil and remoteDeviceIdentity is nil. If this device is a remote device of an owned identity (thus the current device of this identity on some other physical device), then currentDeviceIdentity is nil and remoteDeviceIdentity is not nil. In both cases, one (and only one) of these two relationships is not nil. This is captured by the computed variable `identity`.
    private(set) var currentDeviceIdentity: OwnedIdentity? {
        get {
            let item = kvoSafePrimitiveValue(forKey: Predicate.Key.currentDeviceIdentity.rawValue) as! OwnedIdentity?
            item?.obvContext = self.obvContext
            return item
        }
        set {
            kvoSafeSetPrimitiveValue(newValue, forKey: Predicate.Key.currentDeviceIdentity.rawValue)
        }
    }
    
    private(set) var remoteDeviceIdentity: OwnedIdentity? {
        get {
            let item = kvoSafePrimitiveValue(forKey: Predicate.Key.remoteDeviceIdentity.rawValue) as! OwnedIdentity?
            item?.obvContext = self.obvContext
            return item
        }
        set {
            kvoSafeSetPrimitiveValue(newValue, forKey: Predicate.Key.remoteDeviceIdentity.rawValue)
        }
    }
    
    private var isCurrentDevice: Bool {
        get throws {
            if currentDeviceIdentity != nil && remoteDeviceIdentity == nil {
                return true
            } else  if currentDeviceIdentity == nil && remoteDeviceIdentity != nil {
                return false
            } else {
                throw ObvError.unexpectedValuesForCurrentDevice
            }
        }
    }
    
    var infos: (name: String?, expirationDate: Date?, latestRegistrationDate: Date?) {
        return (self.name, self.expirationDate, self.latestRegistrationDate)
    }
    
    // MARK: Other variables
    
    weak var obvContext: ObvContext?
    weak var delegateManager: ObvIdentityDelegateManager?
    var identity: OwnedIdentity? {
        if let currentDeviceIdentity {
            currentDeviceIdentity.delegateManager = delegateManager
            return currentDeviceIdentity
        } else if let remoteDeviceIdentity {
            remoteDeviceIdentity.delegateManager = delegateManager
            return remoteDeviceIdentity
        } else {
            // Happens if the device was just deleted
            return nil
        }
    }
    private var ownedCryptoIdentityOnDeletion: ObvCryptoIdentity?

    private var changedKeys = Set<String>()
    
    var remoteOwnedDeviceHasPrekey: Bool {
        preKeyForRemoteOwnedDevice != nil
    }

    /// This is only set while inserting a new `OwnedDevice`. This is `true` iff the inserted instance was performed during a `ChannelCreationWithOwnedDeviceProtocol`.
    ///
    /// This value is used in the notification sent to the engine. When receiving the notification, the engine starts a new `ChannelCreationWithOwnedDeviceProtocol` *unless* this Boolean is `true`.
    private var createdDuringChannelCreation: Bool?
    
    // MARK: - Initializers
    
    /// This initializer creates the current device of the owned identity. It should only be called at the time we create an owned identity.
    private convenience init?(ownedIdentity: OwnedIdentity, name: String, with prng: PRNGService, delegateManager: ObvIdentityDelegateManager) {
        guard let obvContext = ownedIdentity.obvContext else {
            let log = OSLog(subsystem: delegateManager.logSubsystem, category: "OwnedDevice")
            os_log("Could not get a context", log: log, type: .fault)
            return nil
        }
        
        let entityDescription = NSEntityDescription.entity(forEntityName: OwnedDevice.entityName, in: obvContext)!
        self.init(entity: entityDescription, insertInto: obvContext)
        
        self.expirationDate = nil // Set later
        self.latestRegistrationDate = nil // Set later
        let trimmedName = name.trimmingWhitespacesAndNewlines()
        self.name = trimmedName.isEmpty ? nil : trimmedName
        self.rawCapabilities = nil // Set bellow
        self.uid = UID.gen(with: prng)
        
        self.currentDeviceIdentity = ownedIdentity
        self.remoteDeviceIdentity = nil

        self.delegateManager = delegateManager
        self.createdDuringChannelCreation = false // As we are creating the current device
        
        let capabilitiesForCurrentDevice: Set<ObvCapability> = Set(ObvCapability.allCases.filter { capability in
            switch capability {
            case .webrtcContinuousICE: return true
            case .groupsV2: return true
            case .oneToOneContacts: return true
            }
        })
        self.setCapabilities(newCapabilities: capabilitiesForCurrentDevice)
        
    }
    
    
    static func createCurrentOwnedDevice(ownedIdentity: OwnedIdentity, name: String, with prng: PRNGService, delegateManager: ObvIdentityDelegateManager) -> OwnedDevice? {
        let currentOwnedDevice = Self.init(ownedIdentity: ownedIdentity, name: name, with: prng, delegateManager: delegateManager)
        return currentOwnedDevice
    }

    
    /// This device adds a remote device to the owned identity.
    convenience init?(remoteDeviceUid: UID, ownedIdentity: OwnedIdentity, createdDuringChannelCreation: Bool, delegateManager: ObvIdentityDelegateManager) {
        guard let obvContext = ownedIdentity.obvContext else {
            let log = OSLog(subsystem: delegateManager.logSubsystem, category: "OwnedDevice")
            os_log("Could not get a context", log: log, type: .fault)
            return nil
        }
        
        let entityDescription = NSEntityDescription.entity(forEntityName: OwnedDevice.entityName, in: obvContext)!
        self.init(entity: entityDescription, insertInto: obvContext)
        
        self.expirationDate = nil // Set later
        self.latestRegistrationDate = nil // Set later
        self.name = nil // Set later
        self.rawCapabilities = nil // Set later
        self.uid = remoteDeviceUid
        
        self.currentDeviceIdentity = nil
        self.remoteDeviceIdentity = ownedIdentity
        
        self.delegateManager = delegateManager
        self.createdDuringChannelCreation = createdDuringChannelCreation
    }

    
    /// Used *exclusively* during a backup restore for creating an instance, relatioships are recreated in a second step
    fileprivate convenience init(backupItem: OwnedDeviceBackupItem, within obvContext: ObvContext) {
        
        let entityDescription = NSEntityDescription.entity(forEntityName: OwnedDevice.entityName, in: obvContext)!
        self.init(entity: entityDescription, insertInto: obvContext)
        
        self.expirationDate = nil // Set later
        self.latestRegistrationDate = nil // Set bellow
        self.name = nil // Set later by the engine, using `setCurrentDeviceNameAfterBackupRestore(newName:)`, right after backup restore
        self.rawCapabilities = nil // Set later
        self.uid = backupItem.uid
        
        self.createdDuringChannelCreation = false
        
        let capabilitiesForCurrentDevice: Set<ObvCapability> = Set(ObvCapability.allCases.filter { capability in
            switch capability {
            case .webrtcContinuousICE: return true
            case .groupsV2: return true
            case .oneToOneContacts: return true
            }
        })
        self.setCapabilities(newCapabilities: capabilitiesForCurrentDevice)

    }
    

    /// Used *exclusively* during a snapshot restore for creating an instance, relatioships are recreated in a second step
    fileprivate convenience init(snapshotItem: OwnedDeviceSnapshotItem, within obvContext: ObvContext) {
        
        let entityDescription = NSEntityDescription.entity(forEntityName: OwnedDevice.entityName, in: obvContext)!
        self.init(entity: entityDescription, insertInto: obvContext)
                
        self.expirationDate = nil // Set later
        self.latestRegistrationDate = nil // Set bellow
        let trimmedName = snapshotItem.customDeviceName.trimmingWhitespacesAndNewlines()
        self.name = trimmedName.isEmpty ? nil : trimmedName
        self.rawCapabilities = nil // Set later
        self.uid = snapshotItem.uid
        
        self.createdDuringChannelCreation = false
        
        let capabilitiesForCurrentDevice: Set<ObvCapability> = Set(ObvCapability.allCases.filter { capability in
            switch capability {
            case .webrtcContinuousICE: return true
            case .groupsV2: return true
            case .oneToOneContacts: return true
            }
        })
        self.setCapabilities(newCapabilities: capabilitiesForCurrentDevice)

    }

    
    func setCurrentDeviceNameAfterBackupRestore(newName: String) {
        assert(self.name == nil)
        if self.name != newName {
            self.name = newName
        }
    }
    

    func updateThisDevice(with device: OwnedDeviceDiscoveryResult.Device, serverCurrentTimestamp: Date, delegateManager: ObvIdentityDelegateManager) throws -> DevicePreKey? {
        
        let log = OSLog(subsystem: delegateManager.logSubsystem, category: Self.entityName)

        guard self.uid == device.uid else {
            assertionFailure()
            throw Self.makeError(message: "Unexpected UID")
        }

        if self.expirationDate != device.expirationDate {
            self.expirationDate = device.expirationDate
        }

        if self.name != device.name {
            self.name = device.name
        }
        
        if self.latestRegistrationDate != device.latestRegistrationDate {
            self.latestRegistrationDate = device.latestRegistrationDate
        }
        
        // If self is a remote owned device, we save the current pre-key value if the server returned one
        
        if try self.isCurrentDevice {
            
            let preKeyToUploadForCurrentDevice = try updateThisCurrentOwnedDevicePreKey(device: device,
                                                                                        serverCurrentTimestamp: serverCurrentTimestamp,
                                                                                        delegateManager: delegateManager)
            return preKeyToUploadForCurrentDevice
                        
        } else {
            
            updateThisRemoteOwnedDevicePreKey(device: device,
                                              serverCurrentTimestamp: serverCurrentTimestamp,
                                              log: log)
            
            return nil
            
        }
        
    }
    
    
    /// Helper method for ``updateThisDevice(with:serverCurrentTimestamp:delegateManager:)``. It is called during the processing of a ``OwnedDeviceDiscoveryResult.Device`` in case the concerned device is a remote owned device.
    private func updateThisRemoteOwnedDevicePreKey(device: OwnedDeviceDiscoveryResult.Device, serverCurrentTimestamp: Date, log: OSLog) {
        
        deleteThisRemoteOwnedDevicePreKeyIfExpired(serverCurrentTimestamp: serverCurrentTimestamp)
        
        if let deviceBlobOnServer = device.deviceBlobOnServer {
            
            // Note that the signature on the deviceBlobOnServer has already been verified

            if deviceBlobOnServer.deviceBlob.devicePreKey.expirationTimestamp > serverCurrentTimestamp {
                do {
                    let devicePreKey = deviceBlobOnServer.deviceBlob.devicePreKey
                    // If the prekey is identical to the one we already have, do nothing. Otherwise, delete the current one and create a new one.
                    if self.preKeyForRemoteOwnedDevice?.cryptoKeyId == devicePreKey.keyId {
                        // Do nothing
                    } else {
                        try self.preKeyForRemoteOwnedDevice?.deletePreKeyForRemoteOwnedDevice()
                        _ = try PreKeyForRemoteOwnedDevice(deviceBlobOnServer: deviceBlobOnServer, forRemoteOwnedDevice: self)
                    }
                } catch {
                    os_log("Failed to save preKey on server for a remote owned device: %{public}@", log: log, type: .fault, error.localizedDescription)
                    assertionFailure()
                }
            } else {
                do {
                    try self.preKeyForRemoteOwnedDevice?.deletePreKeyForRemoteOwnedDevice()
                } catch {
                    os_log("Failed to delete preKey on server for a remote owned device: %{public}@", log: log, type: .fault, error.localizedDescription)
                    assertionFailure()
                }
            }
            
            if self.rawCapabilities == nil {
                setCapabilities(newCapabilities: deviceBlobOnServer.deviceBlob.deviceCapabilities)
            }
            
        }
                        
    }
    
    
    /// Helper method for ``updateThisDevice(with:serverCurrentTimestamp:delegateManager:)``. It is called during the processing of a ``OwnedDeviceDiscoveryResult.Device`` in case the concerned device is the current owned device.
    /// This method returns a `DevicePreKey` iff it should be uploaded to the server.
    private func updateThisCurrentOwnedDevicePreKey(device: OwnedDeviceDiscoveryResult.Device, serverCurrentTimestamp: Date, delegateManager: ObvIdentityDelegateManager) throws -> DevicePreKey? {

        // Note that we do not delete expired pre-keys for the current device. This is not performed during the processing of an owned device discovery, but only after a successful
        // not-truncated list on the server.

        enum CreateOrReturnPreKeyForCurrentOwnedDevice {
            case no
            case createPreKey
            case returnPreKey(devicePreKey: DevicePreKey)
        }

        // Check whether we locally have a pre-key for the server
        let appropriateKeyForServer = self.preKeysForCurrentDevice
            .filter({ !$0.isDeleted })
            .filter({ $0.serverTimestampOnCreation.addingTimeInterval(ObvConstants.preKeyForCurrentDeviceRenewTimeInterval) > serverCurrentTimestamp }) // keep keys that don't need to be renewed
            .compactMap(\.preKey)
            .filter({ $0.expirationTimestamp > serverCurrentTimestamp }) // keep non-expired keys
            .max(by: { $0.expirationTimestamp < $1.expirationTimestamp })

        let createOrReturnPreKeyForCurrentOwnedDevice: CreateOrReturnPreKeyForCurrentOwnedDevice
        
        if let deviceBlobOnServer = device.deviceBlobOnServer {
            
            let devicePreKey = deviceBlobOnServer.deviceBlob.devicePreKey
            
            // There is a pre-key on the server. We check if it is appropriate.
            
            if let appropriateKeyForServer {
                
                if appropriateKeyForServer.keyId == devicePreKey.keyId {
                    // We already created an appropriate key for the server, and it corresponds to the one on the server. There is nothing to do
                    createOrReturnPreKeyForCurrentOwnedDevice = .no
                } else {
                    // We already created an appropriate key for the server, but it does not correspond to the one on the server. We should update the key on the server.
                    if appropriateKeyForServer.expirationTimestamp > devicePreKey.expirationTimestamp {
                        createOrReturnPreKeyForCurrentOwnedDevice = .returnPreKey(devicePreKey: appropriateKeyForServer)
                    } else {
                        createOrReturnPreKeyForCurrentOwnedDevice = .createPreKey
                    }
                }
                
            } else {
                
                // We don't have an (local) appropriate key for the server, we need to create a new one as the one on the server cannot be appropriate
                
                createOrReturnPreKeyForCurrentOwnedDevice = .createPreKey
                
            }
            
        } else {
            
            // There is no pre-key on the server
            
            if let appropriateKeyForServer {
                createOrReturnPreKeyForCurrentOwnedDevice = .returnPreKey(devicePreKey: appropriateKeyForServer)
            } else {
                createOrReturnPreKeyForCurrentOwnedDevice = .createPreKey
            }
            
        }
        
        // Depending on createOrReturnPreKeyForCurrentOwnedDevice, we might need to create a pre-key or to return an existing one
        
        switch createOrReturnPreKeyForCurrentOwnedDevice {

        case .no:
            
            return nil
            
        case .createPreKey:
            
            let devicePreKey = try PreKeyForCurrentOwnedDevice.createPreKeyForCurrentOwnedDevice(forCurrentOwnedDevice: self, serverCurrentTimestamp: serverCurrentTimestamp, prng: delegateManager.prng)
            return devicePreKey

        case .returnPreKey(devicePreKey: let devicePreKey):
            
            return devicePreKey
            
        }
        
    }
    
    
    /// Helper method for ``updateThisRemoteOwnedDevicePreKey(device:serverCurrentTimestamp:log:)``
    private func deleteThisRemoteOwnedDevicePreKeyIfExpired(serverCurrentTimestamp: Date) {
        assert((try? isCurrentDevice) == false)
        guard let expirationTimestamp = self.preKeyForRemoteOwnedDevice?.expirationTimestamp else { return }
        if expirationTimestamp < serverCurrentTimestamp {
            do {
                try self.preKeyForRemoteOwnedDevice?.deletePreKeyForRemoteOwnedDevice()
                self.preKeyForRemoteOwnedDevice = nil
            } catch {
                assertionFailure()
            }
        }
    }
    
    
    func deleteThisCurrentOwnedDeviceExpiredPreKeys(downloadTimestampFromServer: Date) throws {
        assert((try? isCurrentDevice) == true)
        try PreKeyForCurrentOwnedDevice.deleteExpiredPreKeysForCurrentOwnedDevice(self, downloadTimestampFromServer: downloadTimestampFromServer)
    }
    
        
    func deleteThisDevice(delegateManager: ObvIdentityDelegateManager) throws {
        guard let context = managedObjectContext else { throw Self.makeError(message: "No context") }
        ownedCryptoIdentityOnDeletion = identity?.cryptoIdentity
        self.delegateManager = delegateManager
        context.delete(self)
    }
    
}


// MARK: - Latest Channel Creation Ping Timestamp

extension OwnedDevice {
    
    func setLatestChannelCreationPingTimestamp(to newValue: Date) {
        if self.latestChannelCreationPingTimestamp != newValue {
            self.latestChannelCreationPingTimestamp = newValue
        }
    }
    
}


// MARK: - Using pre-keys for encryption

extension OwnedDevice {
    
    func wrapForRemoteOwnedDevice(_ messageKey: any AuthenticatedEncryptionKey, with ownedPrivateKeyForAuthentication: any PrivateKeyForAuthentication, and ownedPublicKeyForAuthentication: any PublicKeyForAuthentication, prng: any PRNGService) throws -> EncryptedData? {

        guard let preKeyForRemoteOwnedDevice else { return nil }
        
        let wrappedMessageKey = try preKeyForRemoteOwnedDevice.wrap(messageKey,
                                                                    with: ownedPrivateKeyForAuthentication,
                                                                    and: ownedPublicKeyForAuthentication,
                                                                    prng: prng)
        
        return wrappedMessageKey

    }
    
    
    func unwrapForCurrentOwnedDevice(_ wrappedMessageKey: EncryptedData) throws -> (messageKey: any AuthenticatedEncryptionKey, remoteCryptoId: ObvCryptoIdentity, remoteDeviceUID: UID)? {
        
        guard try isCurrentDevice else { assertionFailure(); return nil }
        
        return try PreKeyForCurrentOwnedDevice.unwrapMessageKey(wrappedMessageKey, forCurrentOwnedDevice: self)
        
    }
    
}


// MARK: - Errors

extension OwnedDevice {
    
    enum ObvError: Error {
        case unexpectedValuesForCurrentDevice
    }
    
}

// MARK: - Capabilities

extension OwnedDevice {
    
    /// Returns `nil` if the device capabilities were never set yet
    var allCapabilities: Set<ObvCapability>? {
        guard let rawCapabilities = self.rawCapabilities else { return nil }
        let split = rawCapabilities.split(separator: "|")
        return Set(split.compactMap({ ObvCapability(rawValue: String($0)) }))
    }

    func setCapabilities(newCapabilities: Set<ObvCapability>) {
        let newRawCapabilities = Set(newCapabilities.map({ $0.rawValue }))
        self.setRawCapabilities(newRawCapabilities: newRawCapabilities)
    }
    
    func setRawCapabilities(newRawCapabilities: Set<String>) {
        self.rawCapabilities = newRawCapabilities.joined(separator: "|")
    }
    
}


// MARK: - Convenience DB getters

extension OwnedDevice {
    
    @nonobjc class func fetchRequest() -> NSFetchRequest<OwnedDevice> {
        return NSFetchRequest<OwnedDevice>(entityName: OwnedDevice.entityName)
    }
    
    
    struct Predicate {
        enum Key: String {
            case uid = "uid"
            case rawCapabilities = "rawCapabilities"
            case currentDeviceIdentity = "currentDeviceIdentity"
            case remoteDeviceIdentity = "remoteDeviceIdentity"
            case latestChannelCreationPingTimestamp = "latestChannelCreationPingTimestamp"
        }
        static func withUid(_ uid: UID) -> NSPredicate {
            NSPredicate(format: "%K == %@", Key.uid.rawValue, uid)
        }
        fileprivate static func withLatestChannelCreationPingTimestamp(earlierThan date: Date) -> NSPredicate {
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(withNilValueForKey: Key.latestChannelCreationPingTimestamp),
                NSPredicate(Key.latestChannelCreationPingTimestamp, earlierThan: date),
            ])
        }
    }

    
    /// This class method returns an OwnedDevice, but only if it is the current device.
    static func get(currentDeviceUid: UID, delegateManager: ObvIdentityDelegateManager, within obvContext: ObvContext) throws -> OwnedDevice? {
        let request: NSFetchRequest<OwnedDevice> = OwnedDevice.fetchRequest()
        request.predicate = Predicate.withUid(currentDeviceUid)
        let item = (try obvContext.fetch(request)).first
        if item?.currentDeviceIdentity == nil {
            return nil
        }
        item?.delegateManager = delegateManager
        return item
    }

    /// This class method returns an OwnedDevice, but only if it is *not* the current device.
    static func get(remoteDeviceUid: UID, delegateManager: ObvIdentityDelegateManager, within obvContext: ObvContext) throws -> OwnedDevice? {
        let request: NSFetchRequest<OwnedDevice> = OwnedDevice.fetchRequest()
        request.predicate = Predicate.withUid(remoteDeviceUid)
        let item = (try obvContext.fetch(request)).first
        if item?.remoteDeviceIdentity == nil {
            return nil
        }
        item?.delegateManager = delegateManager
        return item
    }
    
    
    static func getAllOwnedRemoteDeviceUids(within obvContext: ObvContext) throws -> Set<ObliviousChannelIdentifier> {
        let request: NSFetchRequest<OwnedDevice> = OwnedDevice.fetchRequest()
        let items = try obvContext.fetch(request)
        let values: Set<ObliviousChannelIdentifier> = Set(items.compactMap {
            guard let identity = $0.identity, identity.currentDeviceUid != $0.uid else { return nil }
            return ObliviousChannelIdentifier(currentDeviceUid: identity.currentDeviceUid, remoteCryptoIdentity: identity.cryptoIdentity, remoteDeviceUid: $0.uid)
        })
        return values
    }
    
    
    static func getAllOwnedRemoteDeviceUidsWithLatestChannelCreationPingTimestamp(earlierThan date: Date, within context: NSManagedObjectContext) throws -> Set<ObliviousChannelIdentifier> {
        let request: NSFetchRequest<OwnedDevice> = OwnedDevice.fetchRequest()
        request.predicate = Predicate.withLatestChannelCreationPingTimestamp(earlierThan: date)
        request.fetchBatchSize = 500
        let items = try context.fetch(request)
        let values: Set<ObliviousChannelIdentifier> = Set(items.compactMap {
            guard let identity = $0.identity, identity.currentDeviceUid != $0.uid else { return nil }
            return ObliviousChannelIdentifier(currentDeviceUid: identity.currentDeviceUid, remoteCryptoIdentity: identity.cryptoIdentity, remoteDeviceUid: $0.uid)
        })
        return values
    }
    
}


// MARK: - Notify on changes

extension OwnedDevice {
    
    override func willSave() {
        super.willSave()
        
        changedKeys = Set<String>(self.changedValues().keys)

    }

    override func didSave() {
        super.didSave()
        
        defer {
            changedKeys.removeAll()
        }

        guard let delegateManager = delegateManager else {
            let log = OSLog.init(subsystem: ObvIdentityDelegateManager.defaultLogSubsystem, category: OwnedDevice.entityName)
            os_log("The delegate manager is not set (1) - Ok during a backup restore or when deleting the corresponding profile", log: log, type: .error)
            return
        }

        let log = OSLog(subsystem: delegateManager.logSubsystem, category: OwnedDevice.entityName)

        guard let flowId = obvContext?.flowId else {
            os_log("The obvContext is not set", log: log, type: .fault)
            assertionFailure()
            return
        }

        if !isDeleted && changedKeys.contains(Predicate.Key.rawCapabilities.rawValue), let identity = self.identity {
            // We do *not* send the device's capabilities. Eventually, the app will request the capabilities of the owned identity that will compute her capabilities on the basis of the capabilities of all her owned devices.
            ObvIdentityNotificationNew.ownedIdentityCapabilitiesWereUpdated(ownedIdentity: identity.cryptoIdentity, flowId: flowId)
                .postOnBackgroundQueue(delegateManager.queueForPostingNotifications, within: delegateManager.notificationDelegate)
        }
        
        if !isDeleted && !changedKeys.isEmpty, let identity = self.identity {
            ObvIdentityNotificationNew.anOwnedDeviceWasUpdated(ownedCryptoId: identity.cryptoIdentity)
                .postOnBackgroundQueue(delegateManager.queueForPostingNotifications, within: delegateManager.notificationDelegate)
        }
        
        if isInserted {
            if let remoteDeviceIdentity {
                assert(createdDuringChannelCreation != nil)
                let createdDuringChannelCreation = self.createdDuringChannelCreation ?? false
                ObvIdentityNotificationNew.newRemoteOwnedDevice(ownedCryptoId: remoteDeviceIdentity.cryptoIdentity, remoteDeviceUid: uid, createdDuringChannelCreation: createdDuringChannelCreation)
                    .postOnBackgroundQueue(delegateManager.queueForPostingNotifications, within: delegateManager.notificationDelegate)
            }
        }
        
        if isDeleted, let ownedCryptoIdentityOnDeletion {
            ObvIdentityNotificationNew.anOwnedDeviceWasDeleted(ownedCryptoId: ownedCryptoIdentityOnDeletion)
                .postOnBackgroundQueue(delegateManager.queueForPostingNotifications, within: delegateManager.notificationDelegate)
        }
        
    }
}


// MARK: - For Backup purposes

extension OwnedDevice {
    
    var backupItem: OwnedDeviceBackupItem {
        return OwnedDeviceBackupItem(uid: self.uid)
    }
    
}


struct OwnedDeviceBackupItem: Codable, Hashable {
    
    fileprivate let uid: UID
    
    fileprivate init(uid: UID) {
        self.uid = uid
    }
    
    enum CodingKeys: String, CodingKey {
        case uid = "uid"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid.raw, forKey: .uid)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawUid = try values.decode(Data.self, forKey: .uid)
        guard let uid = UID(uid: rawUid) else {
            throw ObvError.couldNotRecoverUID
        }
        self.uid = uid
    }
    
    func restoreRelationships(associations: BackupItemObjectAssociations, within obvContext: ObvContext) throws {
        // Nothing do to here
    }

    static func generateNewCurrentDevice(prng: PRNGService, within obvContext: ObvContext) -> OwnedDevice {
        let uid = UID.gen(with: prng)
        let dummyBackupItem = OwnedDeviceBackupItem(uid: uid)
        let currentDevice = OwnedDevice(backupItem: dummyBackupItem, within: obvContext)
        return currentDevice
    }
    
    enum ObvError: Error {
        case couldNotRecoverUID
    }
}


// For snapshot purposes

struct OwnedDeviceSnapshotItem {
    
    let uid: UID
    let customDeviceName: String
    
    private init(uid: UID, customDeviceName: String) {
        self.uid = uid
        self.customDeviceName = customDeviceName
    }
    
    static func generateNewCurrentDevice(prng: PRNGService, customDeviceName: String, within obvContext: ObvContext) -> OwnedDevice {
        let uid = UID.gen(with: prng)
        let dummySnapshotItem = Self.init(uid: uid, customDeviceName: customDeviceName)
        return .init(snapshotItem: dummySnapshotItem, within: obvContext)
    }
    
}
