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

import UIKit
import SwiftUI


protocol ProtectedTransferWarningViewControllerDelegate: AnyObject {
    func userWantsToCloseOnboarding(controller: ProtectedTransferWarningViewController) async
    func userWantsToProceedWithAddingDevice(controller: ProtectedTransferWarningViewController) async
}


final class ProtectedTransferWarningViewController: UIHostingController<ProtectedTransferWarningView> {
    
    private weak var delegate: ProtectedTransferWarningViewControllerDelegate?

    init(delegate: ProtectedTransferWarningViewControllerDelegate) {
        let actions = ProtectedTransferWarningViewActions()
        let view = ProtectedTransferWarningView(actions: actions)
        super.init(rootView: view)
        self.delegate = delegate
        actions.delegate = self
    }
    
    
    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        configureNavigation(animated: animated)
    }
    

    private func configureNavigation(animated: Bool) {
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.setNavigationBarHidden(false, animated: animated)
        let handler: UIActionHandler = { [weak self] _ in self?.closeAction() }
        let closeButton = UIBarButtonItem(systemItem: .close, primaryAction: .init(handler: handler))
        navigationItem.rightBarButtonItem = closeButton
    }

    private func closeAction() {
        Task { [weak self] in
            guard let self else { return }
            await delegate?.userWantsToCloseOnboarding(controller: self)
        }
    }

}


// MARK: ProtectedTransferWarningViewActionsProtocol

extension ProtectedTransferWarningViewController: ProtectedTransferWarningViewActionsProtocol {
    
    func userTouchedOkButton() async {
        await delegate?.userWantsToProceedWithAddingDevice(controller: self)
    }
    
    func userTouchedBackButton() async {
        await delegate?.userWantsToCloseOnboarding(controller: self)
    }
    
}


// MARK: - Actions proxy

private final class ProtectedTransferWarningViewActions: ProtectedTransferWarningViewActionsProtocol {
    
    weak var delegate: ProtectedTransferWarningViewActionsProtocol?
    
    func userTouchedOkButton() async {
        await delegate?.userTouchedOkButton()
    }
    
    func userTouchedBackButton() async {
        await delegate?.userTouchedBackButton()
    }
    
}
