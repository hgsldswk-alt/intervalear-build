import Combine
import Foundation
import Security
import StoreKit

actor PurchaseVault {
    private let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.hgsldswk.intervalear.entitlement",
        kSecAttrAccount as String: "v1"
    ]

    func load(firstOpen: Date) throws -> Entitlement {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound {
            let entitlement = Entitlement(firstOpen: firstOpen, proStartedAt: Launch.hasInAppPurchases ? firstOpen : nil)
            try save(entitlement)
            return entitlement
        }
        guard status == errSecSuccess, let data = value as? Data else { throw Failure.keychain }
        var entitlement = try JSONDecoder().decode(Entitlement.self, from: data)
        if entitlement.proStartedAt == nil && Launch.hasInAppPurchases {
            entitlement.proStartedAt = firstOpen
            try save(entitlement)
        }
        return entitlement
    }

    func save(_ entitlement: Entitlement) throws {
        let data = try JSONEncoder().encode(entitlement)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = identity
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
        } else if status != errSecSuccess { throw Failure.keychain }
    }

    enum Failure: Error { case keychain }
}

@MainActor
final class Purchases: ObservableObject {
    static let proID = "com.hgsldswk.intervalear.pro"
    static let trialID = "com.hgsldswk.intervalear.trial"
    @Published private(set) var state: Entitlement?
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var clock = Date()
    private let openedAt = Date()
    private let vault = PurchaseVault()
    private var listener: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var revision = 0

    var pro: Product? { products.first { $0.id == Self.proID } }
    var trial: Product? { products.first { $0.id == Self.trialID && $0.price == 0 } }
    var hasPro: Bool { !Launch.hasInAppPurchases || state?.hasPro(at: Date()) == true }
    var trialActive: Bool { Launch.hasInAppPurchases && state?.purchasedPro == false && hasPro }
    var daysLeft: Int { max(0, Int(ceil((state?.trialEnd.timeIntervalSinceNow ?? 0) / 86_400))) }

    func start() async {
        guard state == nil else { return }
        if Launch.testing {
            let expired = Launch.has("-expired") || Launch.has("-paywall")
            state = Entitlement(firstOpen: expired ? openedAt.addingTimeInterval(-31 * 86_400) : openedAt, purchasedPro: Launch.has("-purchased"))
            return
        }
        do { state = try await vault.load(firstOpen: openedAt) }
        catch { message = "purchase.storage"; return }
        guard Launch.hasInAppPurchases else { return }
        tick()
        listener = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result,
                   [Self.proID, Self.trialID].contains(transaction.productID), await self.refresh(observed: transaction) {
                    await transaction.finish()
                }
            }
        }
        async let rights: Bool = refresh()
        await loadProducts()
        _ = await rights
    }

    func tick() {
        guard Launch.hasInAppPurchases else { return }
        clock = Date()
        expiry?.cancel()
        if let state, state.trialEnd > clock, !state.purchasedPro {
            let delay = min(state.trialEnd.timeIntervalSince(clock), 3600)
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)); self?.tick() } catch { return }
            }
        }
    }

    @discardableResult
    private func refresh(restoring: Bool = false, observed: StoreKit.Transaction? = nil) async -> Bool {
        guard var next = state else { return false }
        revision += 1
        let ticket = revision
        var owned = false
        var trialDate: Date?
        var uncertain = false
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction) where transaction.revocationDate == nil:
                if transaction.productID == Self.proID { owned = true }
                if transaction.productID == Self.trialID { trialDate = min(trialDate ?? transaction.originalPurchaseDate, transaction.originalPurchaseDate) }
            case .unverified(let transaction, _) where [Self.proID, Self.trialID].contains(transaction.productID): uncertain = true
            default: break
            }
        }
        if let observed, observed.productID == Self.proID, observed.revocationDate != nil {
            owned = false
        } else if !owned, next.purchasedPro, !restoring {
            switch await StoreKit.Transaction.latest(for: Self.proID) {
            case .some(.verified(let transaction)): owned = transaction.revocationDate == nil
            case .some(.unverified(_, _)): uncertain = true
            case nil: owned = true
            }
        }
        guard ticket == revision, !uncertain else { return false }
        next.reconcile(pro: owned, trial: trialDate)
        do {
            if next != state { try await vault.save(next) }
            guard ticket == revision else { return false }
            state = next
            tick()
            return true
        } catch { message = "purchase.storage"; return false }
    }

    func loadProducts() async {
        guard Launch.hasInAppPurchases, !Launch.testing else { return }
        do { products = try await Product.products(for: [Self.proID, Self.trialID]) }
        catch { products = [] }
    }

    func buy(_ product: Product) async {
        guard Launch.hasInAppPurchases, !busy, !Launch.testing else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                if await refresh(observed: transaction) { await transaction.finish(); message = "purchase.saved" }
                else { message = "purchase.verify" }
            case .success(.unverified(_, _)): message = "purchase.verify"
            case .pending: message = "purchase.pending"
            case .userCancelled: break
            @unknown default: message = "purchase.verify"
            }
        } catch { message = "purchase.verify" }
    }

    func restore() async {
        guard Launch.hasInAppPurchases, !busy, !Launch.testing else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            if state == nil { state = try await vault.load(firstOpen: openedAt) }
            if await refresh(restoring: true) { message = state?.purchasedPro == true || state?.trialClaimedAt != nil ? "purchase.restored" : "purchase.none" }
            else { message = "purchase.verify" }
        } catch { message = "purchase.verify" }
    }
}
