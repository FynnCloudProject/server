import Vapor

struct QuotaDTO: Content {
    let used: Int64
    let limit: Int64
    let percentage: Double
    let tierName: String

    init(used: Int64, limit: Int64, tierName: String) {
        self.used = used
        self.limit = limit
        self.tierName = tierName
        // Calculate percentage for the frontend progress bar
        if limit > 0 {
            self.percentage = (Double(used) / Double(limit)) * 100
        } else {
            self.percentage = 0
        }
    }
}
