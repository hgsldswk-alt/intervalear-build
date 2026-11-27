import Foundation

enum Launch {
    enum Distribution {
        case freeDownload, paidDownload, trialWithInAppPurchase

        var hasInAppPurchases: Bool { self == .trialWithInAppPurchase }
    }

    static let freePeriod = false
    static let paidDownload = false
    #if DEBUG
    static let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    #else
    static let testing = false
    #endif

    static func has(_ flag: String) -> Bool { testing && ProcessInfo.processInfo.arguments.contains(flag) }
    static var distribution: Distribution {
        if paidDownload || has("-paid-download") { return .paidDownload }
        if (freePeriod || has("-free-mode")) && !has("-expired") && !has("-paywall") && !has("-paid-mode") {
            return .freeDownload
        }
        return .trialWithInAppPurchase
    }

    static var hasInAppPurchases: Bool { distribution.hasInAppPurchases }
}
