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
import ObvUICoreData
import ObvSystemIcon
import ObvSettings


public extension NewComposeMessageViewSortableAction {
    
    var icon: SystemIcon {
        switch self {
        case .oneTimeEphemeralMessage:
            return .flameFill
        case .scanDocument:
            return .scanner
        case .shootPhotoOrMovie:
            return .camera()
        case .chooseImageFromLibrary:
            return .photo
        case .choseFile:
            return .paperclip
        case .introduceThisContact:
            return .person2Circle
        case .shareLocation:
            return .locationCircle
        }
    }

}


public extension NewComposeMessageViewUnsortableAction {
    
    var icon: SystemIcon {
        switch self {
        case .composeMessageSettings:
            return .gearshapeFill
        }
    }
    
}
