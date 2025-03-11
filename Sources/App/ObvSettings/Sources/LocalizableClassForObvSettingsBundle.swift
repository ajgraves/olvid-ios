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
import SwiftUI


/// This is a dummy class, allowing to specify the appropriate module when declaring a localized string, so that the localized string key is looked up in the correct `Localizable.xcstrings` file.
final class LocalizableClassForObvSettingsBundle {}


func NSLocalizedString(_ key: String, comment: String) -> String {
    return NSLocalizedString(key, tableName: "Localizable", bundle: Bundle(for: LocalizableClassForObvSettingsBundle.self), comment: comment)
}


func NSLocalizedString(_ key: String) -> String {
    return NSLocalizedString(key, tableName: "Localizable", bundle: Bundle(for: LocalizableClassForObvSettingsBundle.self), comment: "Within ObvSettings")
}


extension Text {
  
    init(_ key: LocalizedStringKey, comment: StaticString? = nil) {
        self.init(key, tableName: "Localizable", bundle: Bundle(for: LocalizableClassForObvSettingsBundle.self), comment: comment ?? "Within ObvSettings")
    }

}

extension String {
    
    var localizedInThisBundle: String {
        ObvSettingsResources.bundle.localizedString(forKey: self, value: nil, table: "Localizable")
    }
    
    init(localizedInThisBundle: LocalizationValue) {
        self.init(localized: localizedInThisBundle, table: "Localizable", bundle: ObvSettingsResources.bundle)
    }
    
}
