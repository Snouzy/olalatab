/// Nearest-rank percentiles of a set of durations (any unit).
public struct Percentiles: Equatable, Codable {
    public var count: Int
    public var p50: Double
    public var p99: Double
    public var max: Double

    public init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ p: Double) -> Double {
            let k = Int((p * Double(sorted.count)).rounded(.up))
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, k - 1))]
        }
        count = sorted.count
        p50 = rank(0.50)
        p99 = rank(0.99)
        max = sorted[sorted.count - 1]
    }
}
