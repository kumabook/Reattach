import Observation
import StoreKit

/// Reattach Pro bought on iPhone is a universal purchase, so the Watch reads the same entitlement.
@MainActor
@Observable
final class WatchPro {
    static let shared = WatchPro()

    private(set) var isPro = false
    private let productID = "tokyo.kumabook.tmux.reattach.pro"
    private var updates: Task<Void, Never>?

    private init() {
        #if DEBUG
        isPro = true
        #else
        updates = Task { [weak self] in
            for await _ in Transaction.updates { await self?.refresh() }
        }
        Task { await refresh() }
        #endif
    }

    func refresh() async {
        #if !DEBUG
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        isPro = owned
        #endif
    }
}
