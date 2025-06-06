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
import os.log
import ObvUICoreData
import CoreData
import ObvTypes


final class UpdateProfilePictureOfOwnedIdentityOperation: ContextualOperationWithSpecificReasonForCancel<CoreDataOperationReasonForCancel>, @unchecked Sendable {

    let obvOwnedIdentity: ObvOwnedIdentity
    
    init(obvOwnedIdentity: ObvOwnedIdentity) {
        self.obvOwnedIdentity = obvOwnedIdentity
        super.init()
    }
    
    override func main(obvContext: ObvContext, viewContext: NSManagedObjectContext) {

        do {
            guard let persistedObvOwnedIdentity = try PersistedObvOwnedIdentity.get(persisted: obvOwnedIdentity, within: obvContext.context) else { return }
            persistedObvOwnedIdentity.updatePhotoURL(with: obvOwnedIdentity.publishedIdentityDetails.photoURL)
        } catch {
            return cancel(withReason: .coreDataError(error: error))
        }
        
    }
}
