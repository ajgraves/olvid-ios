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


public enum LocalAuthenticationPolicy: Int, CaseIterable {
    // No authentication
    case none
    // User authentication with biometry, Apple Watch, or the device passcode.
    case deviceOwnerAuthentication
    // User authentication with biometry, with custom passcode fallback
    case biometricsWithCustomPasscodeFallback
    // User authentication with custom passcode only
    case customPasscode

    public var lockScreen: Bool {
        switch self {
        case .none: return false
        case .deviceOwnerAuthentication, .biometricsWithCustomPasscodeFallback, .customPasscode: return true
        }
    }

    public var useCustomPasscode: Bool {
        switch self {
        case .none, .deviceOwnerAuthentication: return false
        case .biometricsWithCustomPasscodeFallback, .customPasscode: return true
        }
    }

    public func isAvailable(whenBestAvailableAuthenticationMethodIs method: AuthenticationMethod) -> Bool {
        switch self {
        case .none:
            return true
        case .deviceOwnerAuthentication:
            return method != .none
        case .biometricsWithCustomPasscodeFallback:
            switch method {
            case .none, .passcode: return false
            case .touchID, .faceID: return true
            }
        case .customPasscode:
            return true
        }
    }

}
