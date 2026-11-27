import ActivityKit

struct PracticeActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var answered: Int
        var total: Int
    }
}
