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
import ObvUICoreData
import ObvSystemIcon


extension PersistedAttachmentSentRecipientInfos.ReceptionStatus {
    
    func getSymbolIcon() -> any SymbolIcon {
        
        switch self {
        case .uploadable:
            return SystemIcon.circleDashed
        case .uploading:
            return SystemIcon.arrowUpCircle
        case .complete:
            return CustomIcon.checkmark
        case .delivered:
            return CustomIcon.checkmarkCircle
        case .read:
            return CustomIcon.checkmarkCircleFill
        }
        
    }
    
}
