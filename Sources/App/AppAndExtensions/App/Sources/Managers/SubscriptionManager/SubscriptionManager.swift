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
import os.log
import ObvEngine
import StoreKit
import ObvTypes
import ObvUICoreData
import ObvAppCoreConstants
import ObvSubscription


final class SubscriptionManager: NSObject, StoreKitDelegate {
    
    private static let allProductIdentifiers = Set(ProductIdentifier.allCases.map(\.rawValue))
    
    private enum ProductIdentifier: String, CaseIterable {
        case ioOlvidPremiumMonthly = "io.olvid.premium_2020_monthly"
    }
            
    private let obvEngine: ObvEngine
    private let log = OSLog(subsystem: ObvAppCoreConstants.logSubsystem, category: String(describing: SubscriptionManager.self))
    
    private var updates: Task<Void, Never>? = nil

    init(obvEngine: ObvEngine) {
        self.obvEngine = obvEngine
        super.init()
    }
    
    deinit {
        updates?.cancel()
    }


    // Called at an appropriate time by the AppManagersHolder
    func listenToSKPaymentTransactions() {
        guard SKPaymentQueue.canMakePayments() else { return }
        self.updates = listenForTransactions()
        
    }
    
    
    private func listenForTransactions() -> Task<Void, Never> {
        return Task(priority: .background) {
            for await verificationResult in Transaction.updates {
                do {
                    _ = try await self.handle(updatedTransaction: verificationResult)
                } catch {
                    assertionFailure()
                    os_log("💰 Could not handle the updated transaction: %{public}@", log: log, type: .fault, error.localizedDescription)
                }
            }
        }
    }
        
}


// MARK: - StoreKitDelegate

extension SubscriptionManager {
    
    /// Called when the user taps on the refresh button. This will look for the current entitlements.
    /// If a valid subscription is found, the server is contacted with this subscription for all
    /// owned identities.
    func userWantsToRefreshSubscriptionStatus() async throws -> [ObvSubscription.StoreKitDelegatePurchaseResult] {
        var results = [StoreKitDelegatePurchaseResult]()
        for await verificationResult in Transaction.currentEntitlements {
            let result = try await handle(updatedTransaction: verificationResult)
            results.append(result)
        }
        return results
    }
    
        
    func userRequestedListOfSKProducts() async throws -> [Product] {

        os_log("💰 User requested a list of available SKProducts", log: log, type: .info)
        
        guard SKPaymentQueue.canMakePayments() else {
            os_log("💰 User is *not* allowed to make payments, returning an empty list of SKProducts", log: log, type: .error)
            throw ObvError.userCannotMakePayments
        }
        
        let storeProducts = try await Product.products(for: SubscriptionManager.allProductIdentifiers)
        
        return storeProducts

    }
    
    
    func userWantsToKnowIfMultideviceSubscriptionIsActive() async throws -> Bool {
        
        let storeProducts = try await userRequestedListOfSKProducts()
        
        for product in storeProducts {
            guard let subscription = product.subscription else { continue }
            guard productIncludesMultiDeviceSubScription(product) else { continue }
            let statuses = try await subscription.status
            for status in statuses {
                switch status.state {
                case .subscribed, .inBillingRetryPeriod, .inGracePeriod:
                    return true
                case .expired, .revoked:
                    continue
                default:
                    assertionFailure()
                    continue
                }
            }
        }
        
        return false
        
    }
    
    
    private func productIncludesMultiDeviceSubScription(_ product: Product) -> Bool {
        guard let productIdentifier = ProductIdentifier(rawValue: product.id) else {
            assertionFailure()
            return false
        }
        switch productIdentifier {
        case .ioOlvidPremiumMonthly:
            return true
        }
    }

    
    func userWantsToBuy(_ product: Product) async throws -> StoreKitDelegatePurchaseResult {
        
        let log = self.log
        os_log("💰 User requested purchase of the SKProduct with identifier %{public}@", log: log, type: .info, product.id)
        
        // 2025-02-25: we used to make sure that the user had at least on active non-keycloak, non-hidden identity.
        // We don't do that anymore, since this method may be called during the first onboarding, while restoring a backup.
        
        // Proceed with the purchase
        
        let result = try await product.purchase()
        
        switch result {
            
        case .success(let verificationResult):
            
            return try await handle(updatedTransaction: verificationResult)
            
        case .userCancelled:
            // No need to throw
            return .userCancelled
            
        case .pending:
            // The purchase requires action from the customer (e.g., parents approval).
            // If the transaction completes,  it's available through Transaction.updates.
            // To listen to these updates, we iterate over `SubscriptionManager.listenForTransactions()`.
            return .pending
            
        @unknown default:
            assertionFailure()
            return .userCancelled
        }
        
    }
    
    
    /// Called either when the user makes a purchase in the app, or when a transaction is obtained in `SubscriptionManager.listenForTransactions()`.
    private func handle(updatedTransaction verificationResult: VerificationResult<Transaction>) async throws -> StoreKitDelegatePurchaseResult {
        
        let (transaction, signedAppStoreTransactionAsJWS, state) = try await checkVerified(verificationResult)
        
        switch state {
        case .subscribed:
            // We will process the purchase at the server level
            break
        case .expired:
            return .expired
        case .inBillingRetryPeriod:
            // We will process the purchase at the server level
            break
        case .inGracePeriod:
            // We will process the purchase at the server level
            break
        case .revoked:
            return .revoked
        default:
            assertionFailure("Add the missing case")
            // We will process the purchase at the server level
            break
        }
        
        let results = try await obvEngine.processAppStorePurchase(signedAppStoreTransactionAsJWS: signedAppStoreTransactionAsJWS, transactionIdentifier: transaction.id)
        
        await transaction.finish()
        
        // Since the same receipt data was used for all appropriate owned identities, we expect all results to be the same. Yet, we have to take into account exceptional circumstances ;-)
        // So we globally fail if any of the results is distinct from `.succeededAndSubscriptionIsValid`.
        
        if results.values.allSatisfy({ $0 == .succeededAndSubscriptionIsValid }) {
            
            os_log("💰 The AppStore receipt was successfully verified by Olvid's server", log: log, type: .info)
            return .purchaseSucceeded(serverVerificationResult: .succeededAndSubscriptionIsValid)
            
        } else if results.values.first(where: { $0 == .succeededButSubscriptionIsExpired }) != nil {
            
            os_log("💰 The AppStore receipt verification succeeded but the subscription has expired", log: log, type: .info)
            return .purchaseSucceeded(serverVerificationResult: .succeededButSubscriptionIsExpired)
            
        } else {
            
            os_log("💰 The AppStore receipt verification failed", log: log, type: .error)
            return .purchaseSucceeded(serverVerificationResult: .failed)
            
        }


    }

    
    func userWantsToRestorePurchases() async throws {
        try await AppStore.sync()
    }
    
}


// MARK: - Helpers

extension SubscriptionManager {
        
    private func checkVerified(_ result: VerificationResult<Transaction>) async throws -> (transaction: Transaction, jwsRepresentation: String, state: Product.SubscriptionInfo.RenewalState?) {
        switch result {
        case .unverified:
            throw ObvError.failedVerification
        case .verified(let signedType):
            let jwsRepresentation = result.jwsRepresentation
            let state = await signedType.subscriptionStatus?.state
            return (signedType, jwsRepresentation, state)
        }
    }

    
    enum ObvError: LocalizedError {
        case transactionHasNoIdentifier
        case couldNotRetrieveAppStoreReceiptURL
        case thereIsNoFileAtTheURLIndicatedInTheTransaction
        case couldReadDataAtTheURLIndicatedInTheTransaction
        case userHasNoActiveIdentity
        case failedVerification
        case userCannotMakePayments
    }
    
}
