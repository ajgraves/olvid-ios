/*
 *  Olvid for iOS
 *  Copyright © 2019-2021 Olvid SAS
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

import UIKit

class ObvSimpleMessageTableViewCell: UITableViewCell {

    static let nibName = "ObvSimpleMessageTableViewCell"
    static let identifier = "ObvSimpleMessageTableViewCell"
    
    // Views
    
    @IBOutlet weak var roundedRectView: ObvRoundedRectView!
    @IBOutlet weak var label: UILabel!
    
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        self.backgroundColor = .clear
        
        roundedRectView.backgroundColor = appTheme.colorScheme.secondarySystemBackground
        
        label.textColor = appTheme.colorScheme.label
        label.font = UIFont.preferredFont(forTextStyle: .callout)
        label.numberOfLines = 0
        
    }
}
