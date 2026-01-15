import Foundation

actor OrderMonitor {
    static let shared = OrderMonitor()
    
    private var quotes: QuoteService = QuoteService()
    private var running = false
    private let heartbeatKey = "order_monitor_last_tick"
    
    func setQuoteService(_ svc: QuoteService?) {
        self.quotes = svc ?? QuoteService()
    }
    
    func start() {
        guard !running else { return }
        running = true
        Task.detached { [weak self] in
            guard let self = self else { return }
            await self.loop()
        }
    }
    
    func stop() {
        running = false
    }
    
    func getLastHeartbeat() -> Date? {
        return UserDefaults.standard.object(forKey: heartbeatKey) as? Date
    }
    
    private func writeHeartbeat() {
        UserDefaults.standard.set(Date(), forKey: heartbeatKey)
    }
    
    private func loop() async {
        while running {
            await tick()
            writeHeartbeat()
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
    }
    
    private func tick() async {
        let orders = await OrderStore.shared.load()
        let working = orders.filter { $0.status == .working }
        
        for ord in working {
            guard let exp = ord.expiration else { continue }
            do {
                let chain = try await quotes.fetchOptionChain(symbol: ord.symbol, expiration: exp)
                let contracts: [OptionContract]
                if ord.right.lowercased() == "call" {
                    contracts = chain.callContracts
                } else if ord.right.lowercased() == "put" {
                    contracts = chain.putContracts
                } else {
                    continue
                }
                guard let contract = contracts.first(where: { $0.strike == ord.strike }) else { continue }
                
                let bid = contract.bid
                let ask = contract.ask
                let last = contract.last
                let mid: Double?
                if let b = bid, let a = ask, b > 0, a > 0 {
                    mid = (b + a) / 2
                } else if let b = bid {
                    mid = b
                } else if let a = ask {
                    mid = a
                } else {
                    mid = last
                }
                
                let isBuy = ord.side.lowercased() == "buy"
                guard let limit = ord.limit else { continue }
                
                let crosses: Bool
                if isBuy {
                    crosses = (ask != nil && ask! <= limit) || (mid != nil && mid! <= limit)
                } else {
                    crosses = (bid != nil && bid! >= limit) || (mid != nil && mid! >= limit)
                }
                
                if crosses {
                    let execPrice: Double
                    if isBuy {
                        if let a = ask {
                            execPrice = min(a, limit)
                        } else if let m = mid {
                            execPrice = min(m, limit)
                        } else {
                            execPrice = limit
                        }
                    } else {
                        if let b = bid {
                            execPrice = max(b, limit)
                        } else if let m = mid {
                            execPrice = max(m, limit)
                        } else {
                            execPrice = limit
                        }
                    }
                    await OrderStore.shared.update(id: ord.id) { order in
                        order.status = .filled
                        order.fillPrice = execPrice
                        order.fillQuantity = order.quantity
                    }
                } else {
                    if exp < Date() {
                        await OrderStore.shared.update(id: ord.id) { order in
                            order.status = .canceled
                        }
                    } else if ord.tif.uppercased() == "DAY" && !Calendar.current.isDate(ord.placedAt, inSameDayAs: Date()) {
                        await OrderStore.shared.update(id: ord.id) { order in
                            order.status = .canceled
                        }
                    }
                }
            } catch {
                // Ignore errors
            }
        }
    }
}


