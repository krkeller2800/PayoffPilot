import Foundation

// Top-level supporting types formerly nested in TradingService
struct OrderRequest {
    var symbol: String
    var option: OptionSpec
    var side: Side
    var quantity: Int
    var limit: Double
    var tif: TIF
}

struct OptionSpec {
    var expiration: Date
    var right: OptionRight
    var strike: Double
}

enum OptionRight {
    case call, put
}

enum Side {
    case buy, sell
}

enum TIF {
    case day, gtc
}

struct PlacedOrder {
    var id: String
    var status: Status
}

enum Status {
    case accepted
    case rejected(String)
}

struct OrderFill {
    var price: Double
    var quantity: Int
    var timestamp: Date
}

struct OrderResult {
    var placed: PlacedOrder
    var fill: OrderFill?
}

// Protocol now references top-level types
protocol TradingService {
    func placeOptionOrder(_ request: OrderRequest) async throws -> OrderResult
}
