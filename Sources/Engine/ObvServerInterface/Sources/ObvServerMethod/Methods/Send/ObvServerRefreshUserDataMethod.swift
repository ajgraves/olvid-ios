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
import ObvMetaManager
import OlvidUtils

public final class ObvServerRefreshUserDataMethod: ObvServerDataMethod {

    static let log = OSLog(subsystem: "io.olvid.server.interface.ObvServerPutUserDataMethod", category: "ObvServerInterface")

    public let pathComponent = "/refreshUserData"

    public var ownedIdentity: ObvCryptoIdentity? { ownedCryptoId }
    private let ownedCryptoId: ObvCryptoIdentity
    public let isActiveOwnedIdentityRequired = true
    public var serverURL: URL { ownedCryptoId.serverURL }
    public let token: Data
    public let serverLabel: UID
    public let flowId: FlowIdentifier

    weak public var identityDelegate: ObvIdentityDelegate? = nil

    public init(ownedIdentity: ObvCryptoIdentity, token: Data, serverLabel: UID, flowId: FlowIdentifier) {
        self.ownedCryptoId = ownedIdentity
        self.token = token
        self.serverLabel = serverLabel
        self.flowId = flowId
    }

    public enum PossibleReturnStatus: UInt8 {
        case ok = 0x00
        case invalidToken = 0x04
        case deletedFromServer = 0x09
        case generalError = 0xff
    }

    lazy public var dataToSend: Data? = {
        return [self.ownedCryptoId, self.token, self.serverLabel].obvEncode().rawData
    }()

    public static func parseObvServerResponse(responseData: Data, using log: OSLog) -> PossibleReturnStatus? {

        guard let (rawServerReturnedStatus, _) = genericParseObvServerResponse(responseData: responseData, using: log) else {
            os_log("Could not parse the server response", log: log, type: .error)
            return nil
        }

        guard let serverReturnedStatus = PossibleReturnStatus(rawValue: rawServerReturnedStatus) else {
            os_log("The returned server status is invalid", log: log, type: .error)
            return nil
        }

        return serverReturnedStatus
    }

}
