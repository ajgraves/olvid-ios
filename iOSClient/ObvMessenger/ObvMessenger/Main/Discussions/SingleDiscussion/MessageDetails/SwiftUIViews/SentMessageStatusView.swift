/*
 *  Olvid for iOS
 *  Copyright © 2019-2022 Olvid SAS
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

import SwiftUI


struct SentMessageStatusView: View {
    
    let forStatus: PersistedMessageSent.MessageStatus
    var dateAsString: String?
    
    private var icon: ObvSystemIcon {
        switch forStatus {
        case .unprocessed:
            return .hourglass
        case .processing:
            return .hare
        case .sent:
            return .checkmarkCircle
        case .delivered:
            return .checkmarkCircleFill
        case .read:
            return .eyeFill
        case .couldNotBeSentToOneOrMoreRecipients:
            return .exclamationmarkCircle
        }
    }
    
    private var title: String {
        switch forStatus {
        case .unprocessed: return CommonString.Word.Unprocessed
        case .processing: return CommonString.Word.Processing
        case .sent: return CommonString.Word.Sent
        case .delivered: return CommonString.Word.Delivered
        case .read: return CommonString.Word.Read
        case .couldNotBeSentToOneOrMoreRecipients: return NSLocalizedString("FAILED", comment: "")
        }
    }
    
    private var dateString: String {
        dateAsString ?? "-"
    }
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            ObvLabelAlt(title: title, systemIcon: icon)
            Spacer()
            Text(dateString)
                .font(.body)
                .foregroundColor(Color(AppTheme.shared.colorScheme.secondaryLabel))
        }
    }
    
}



struct SentMessageStatusView_Previews: PreviewProvider {
    
    static var previews: some View {
        Group {
            SentMessageStatusView(forStatus: .read, dateAsString: nil)
            SentMessageStatusView(forStatus: .delivered, dateAsString: "some date")
            SentMessageStatusView(forStatus: .sent, dateAsString: "another date")
        }
        .padding()
        .previewLayout(.fixed(width: 400, height: 70))
    }
}
