import Foundation

struct Entitlement: Codable, Equatable, Sendable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let local = proStartedAt ?? firstOpen
        return min(local, trialClaimedAt ?? local)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    func hasPro(at now: Date, free: Bool = !Launch.hasInAppPurchases) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }

    mutating func reconcile(pro: Bool, trial: Date?) {
        purchasedPro = pro
        if let trial { trialClaimedAt = min(trialClaimedAt ?? trial, trial) }
    }
}
