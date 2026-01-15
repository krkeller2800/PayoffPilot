import Foundation

final class PaperTradingService: TradingService {
    private let quotes: QuoteService
    
    init(quotes: QuoteService) {
        self.quotes = quotes
    }
    
    func placeOptionOrder(_ request: OrderRequest) async throws -> OrderResult {
        let placed = PlacedOrder(id: UUID().uuidString, status: .accepted)
        
        let optionChain = try await quotes.fetchOptionChain(symbol: request.symbol, expiration: request.option.expiration)
        
        let contracts: [OptionContract]
        switch request.option.right {
        case .call:
            contracts = optionChain.callContracts
        case .put:
            contracts = optionChain.putContracts
        }
        
        guard let contract = contracts.first(where: { abs($0.strike - request.option.strike) < 0.0001 }) else {
            return OrderResult(placed: placed, fill: nil)
        }
        
        let bid = contract.bid
        let ask = contract.ask
        _ = contract.last
        let mid = Self.computeMid(bid: bid, ask: ask)
        
        let limit = request.limit
        let side = request.side
        
        let crosses: Bool
        switch side {
        case .buy:
            if let ask = ask {
                crosses = ask <= limit
            } else if let mid = mid {
                crosses = mid <= limit
            } else {
                crosses = false
            }
        case .sell:
            if let bid = bid {
                crosses = bid >= limit
            } else if let mid = mid {
                crosses = mid >= limit
            } else {
                crosses = false
            }
        }
        
        if crosses {
            let rawExecPrice: Double
            switch side {
            case .buy:
                if let ask = ask {
                    rawExecPrice = min(ask, limit)
                } else if let mid = mid {
                    rawExecPrice = min(mid, limit)
                } else {
                    rawExecPrice = limit
                }
            case .sell:
                if let bid = bid {
                    rawExecPrice = max(bid, limit)
                } else if let mid = mid {
                    rawExecPrice = max(mid, limit)
                } else {
                    rawExecPrice = limit
                }
            }
            let execPrice = (rawExecPrice * 100).rounded() / 100
            let fill = OrderFill(price: execPrice, quantity: request.quantity, timestamp: Date())
            return OrderResult(placed: placed, fill: fill)
        } else {
            return OrderResult(placed: placed, fill: nil)
        }
    }
    
    private static func computeMid(bid: Double?, ask: Double?) -> Double? {
        if let bid = bid, let ask = ask {
            return (bid + ask) / 2
        }
        return nil
    }
}
