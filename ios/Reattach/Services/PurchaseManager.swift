//
//  PurchaseManager.swift
//  Reattach
//

import Foundation
import StoreKit
import Observation

@MainActor
@Observable
class PurchaseManager {
    static let shared = PurchaseManager()

    private(set) var isPurchased: Bool = false
    private(set) var isLoading: Bool = false
    var errorMessage: String?

    private let productId = "com.kumabook.reattach.pro"
    private var product: Product?
    private var updateListenerTask: Task<Void, Error>?

    #if DEBUG
    var debugSimulateFreeMode = false
    #endif

    var isPro: Bool {
        #if DEBUG
        return debugSimulateFreeMode ? isPurchased : true
        #else
        return isPurchased
        #endif
    }

    // MARK: - Limits

    static let freeServerLimit = 1
    static let freeBookmarkLimit = 5
    static let freeHistoryLimit = 20
    static let proHistoryLimit = 100

    var serverLimit: Int {
        isPro ? .max : Self.freeServerLimit
    }

    var bookmarkLimit: Int {
        isPro ? .max : Self.freeBookmarkLimit
    }

    var historyLimit: Int {
        isPro ? Self.proHistoryLimit : Self.freeHistoryLimit
    }

    private init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await updatePurchasedStatus()
        }
    }


    // MARK: - Products

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [productId])
            product = products.first
        } catch {
            errorMessage = "Failed to load products: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    func purchase() async -> Bool {
        guard let product else {
            errorMessage = "Product not available"
            return false
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await updatePurchasedStatus()
                return true

            case .userCancelled:
                return false

            case .pending:
                errorMessage = "Purchase is pending"
                return false

            @unknown default:
                return false
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            return false
        }
    }

    func restore() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await updatePurchasedStatus()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try await self.checkVerified(result)
                    await self.updatePurchasedStatus()
                    await transaction.finish()
                } catch {
                    print("Transaction verification failed: \(error)")
                }
            }
        }
    }

    private func updatePurchasedStatus() async {
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                if transaction.productID == productId {
                    isPurchased = true
                    return
                }
            } catch {
                print("Entitlement verification failed: \(error)")
            }
        }
        isPurchased = false
    }

    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Product Info

    var productPrice: String? {
        product?.displayPrice
    }

    var productName: String? {
        product?.displayName
    }
}

enum StoreError: Error {
    case verificationFailed
}
