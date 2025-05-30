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
import ObvTypes
import ObvEngine
import ObvUI
import ObvDesignSystem


final class UserTriesToAccessPaidFeatureHostingController: UIHostingController<UserTriesToAccessPaidFeatureView> {
    
    init(requestedPermission: APIPermissions, ownedCryptoId: ObvCryptoId) {
        let view = UserTriesToAccessPaidFeatureView(requestedPermission: requestedPermission, ownedCryptoId: ownedCryptoId)
        super.init(rootView: view)
    }
    
    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}


struct UserTriesToAccessPaidFeatureView: View {
    
    /// This is the permission required for the feature the user requested but for which she has no permission
    let requestedPermission: APIPermissions
    let ownedCryptoId: ObvCryptoId
    
    private static func getTextFor(permission: APIPermissions) -> Text {
        if permission == .canCall {
            return Text("MESSAGE_SUBSCRIPTION_REQUIRED_CALL")
        } else {
            assertionFailure()
            return Text("MESSAGE_SUBSCRIPTION_REQUIRED_GENERIC")
        }
    }
    
    var body: some View {

        ZStack {
            Color(AppTheme.shared.colorScheme.systemBackground)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .edgesIgnoringSafeArea(.all)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("SUBSCRIPTION_REQUIRED")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.horizontal)
                        .padding(.top)
                    Spacer()
                }
                ScrollView {
                    VStack(spacing: 0) {
                        HStack { Spacer() }
                        ObvCardView {
                            UserTriesToAccessPaidFeatureView.getTextFor(permission: requestedPermission)
                                .frame(minWidth: .none,
                                       maxWidth: .infinity,
                                       minHeight: .none,
                                       idealHeight: .none,
                                       maxHeight: .none,
                                       alignment: .center)
                                .font(.body)
                        }
                        .padding(.bottom)
                        OlvidButton(style: .blue, title: Text("BUTTON_LABEL_CHECK_SUBSCRIPTION"), systemIcon: .eyesInverse) {
                            let deepLink = ObvDeepLink.myId(ownedCryptoId: ownedCryptoId)
                            ObvMessengerInternalNotification.userWantsToNavigateToDeepLink(deepLink: deepLink)
                                .postOnDispatchQueue()
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top)
                }
                Spacer()
            }
        }

    }
}




// MARK: - PreviewProvider

struct UserTriesToAccessPaidFeatureView_Previews: PreviewProvider {
    
    private static let identityAsURL = URL(string: "https://invitation.olvid.io/#AwAAAIAAAAAAXmh0dHBzOi8vc2VydmVyLmRldi5vbHZpZC5pbwAA1-NJhAuO742VYzS5WXQnM3ACnlxX_ZTYt9BUHrotU2UBA_FlTxBTrcgXN9keqcV4-LOViz3UtdEmTZppHANX3JYAAAAAGEFsaWNlIFdvcmsgKENFTyBAIE9sdmlkKQ==")!
    private static let identity = ObvURLIdentity(urlRepresentation: identityAsURL)!

    static var previews: some View {
        Group {
            UserTriesToAccessPaidFeatureView(requestedPermission: .canCall, ownedCryptoId: identity.cryptoId)
                .environment(\.colorScheme, .light)
            UserTriesToAccessPaidFeatureView(requestedPermission: .canCall, ownedCryptoId: identity.cryptoId)
                .environment(\.colorScheme, .dark)
            UserTriesToAccessPaidFeatureView(requestedPermission: .canCall, ownedCryptoId: identity.cryptoId)
                .environment(\.colorScheme, .light)
                .environment(\.locale, .init(identifier: "fr"))
            UserTriesToAccessPaidFeatureView(requestedPermission: .canCall, ownedCryptoId: identity.cryptoId)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, .init(identifier: "fr"))
        }
    }
}
