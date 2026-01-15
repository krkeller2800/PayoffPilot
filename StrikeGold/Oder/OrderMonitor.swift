import Foundation

actor OrderMonitor {
    static let shared = OrderMonitor()
    
    private var quotes: QuoteService = QuoteService()
    private var running = false
    private let heartbeatKey = "order_monitor_last_tick"
    
#if DEBUG
    nonisolated private var debugLogsEnabled: Bool {
        get { OrderMonitor.staticDebugLogsEnabled }
        set { OrderMonitor.staticDebugLogsEnabled = newValue }
    }
    private static var staticDebugLogsEnabled: Bool = false
    nonisolated private func dlog(_ message: @autoclosure () -> String) {
        if OrderMonitor.staticDebugLogsEnabled { print(message()) }
    }
    nonisolated private static func sdlog(_ message: @autoclosure () -> String) {
        if staticDebugLogsEnabled { print(message()) }
    }
    nonisolated func setDebugLogging(_ enabled: Bool) {
        OrderMonitor.staticDebugLogsEnabled = enabled
    }
#endif
    
    // Configure quotes on startup from persisted settings
    init() {
        // Build an initial QuoteService asynchronously on the main actor to respect Keychain isolation.
        self.quotes = QuoteService()
        self.running = false
        // heartbeatKey already initialized by default property value
        Task { @MainActor in
            let svc = OrderMonitor.buildInitialQuoteService()
            await self.setQuoteService(svc)
        }
#if DEBUG
        dlog("[OrderMonitor] init completed. quotes provider configured (default first, then persisted settings applied asynchronously).")
#endif
    }

    /// Construct a QuoteService from persisted provider selection and tokens.
    /// Falls back to a default QuoteService() when no provider is enabled or tokens are missing.
    @MainActor private static func buildInitialQuoteService() -> QuoteService {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: "lastEnabledProvider")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Attempt to restore a provider-specific QuoteService.
        switch last {
        case "Tradier":
            if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradierToken), !token.isEmpty {
#if DEBUG
                OrderMonitor.sdlog("[OrderMonitor] Restoring Tradier provider from Keychain.")
#endif
                let provider = TradierProvider(token: token)
                return QuoteService(provider: provider)
            }
        case "Finnhub":
            if let token = KeychainHelper.load(key: KeychainHelper.Keys.finnhubToken), !token.isEmpty {
#if DEBUG
                OrderMonitor.sdlog("[OrderMonitor] Restoring Finnhub provider from Keychain.")
#endif
                let provider = FinnhubProvider(token: token)
                return QuoteService(provider: provider)
            }
        case "Polygon":
            if let token = KeychainHelper.load(key: KeychainHelper.Keys.polygonToken), !token.isEmpty {
#if DEBUG
                OrderMonitor.sdlog("[OrderMonitor] Restoring Polygon provider from Keychain.")
#endif
                let provider = PolygonProvider(token: token)
                return QuoteService(provider: provider)
            }
        case "TradeStation":
            if let token = KeychainHelper.load(key: KeychainHelper.Keys.tradestationToken), !token.isEmpty {
#if DEBUG
                OrderMonitor.sdlog("[OrderMonitor] Restoring TradeStation provider from Keychain.")
#endif
                let provider = TradeStationProvider(token: token)
                return QuoteService(provider: provider)
            }
        default:
            break
        }

#if DEBUG
        OrderMonitor.sdlog("[OrderMonitor] No persisted provider to restore or token missing. Using default QuoteService().")
#endif
        return QuoteService()
    }
    
    func setQuoteService(_ svc: QuoteService?) {
#if DEBUG
        if svc != nil {
            dlog("[OrderMonitor] setQuoteService called with NON-NIL QuoteService")
        } else {
            dlog("[OrderMonitor] setQuoteService called with NIL QuoteService (will use default)")
        }
#endif
        self.quotes = svc ?? QuoteService()
#if DEBUG
        dlog("[OrderMonitor] setQuoteService completed. quotes now set.")
#endif
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
    
    @MainActor private func writeHeartbeat() {
        let now = Date()
        UserDefaults.standard.set(now, forKey: heartbeatKey)
        NotificationCenter.default.post(
            name: .orderMonitorHeartbeatDidUpdate,
            object: now,
            userInfo: ["date": now]
        )
    }
    
    private func loop() async {
        while running {
            await tick()
            await writeHeartbeat()
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
    }
    
    private func tick() async {
        let orders = await OrderStore.shared.load()
        let working = orders.filter { $0.status == .working }
        
        for ord in working {
#if DEBUG
            if ord.expiration == nil {
                dlog("[OrderMonitor] Skipping order id=\(ord.id) symbol=\(ord.symbol): missing expiration")
            }
#endif
            guard let exp = ord.expiration else { continue }
#if DEBUG
            let expStr = DateFormatter.localizedString(from: exp, dateStyle: .short, timeStyle: .none)
            let now = Date()
            let delta = exp.timeIntervalSince(now)
            dlog("[OrderMonitor] Processing order id=\(ord.id) symbol=\(ord.symbol) exp=\(expStr) tMinusSec=\(Int(delta)) right=\(ord.right.rawValue) strike=\(ord.strike)")
#endif
            
            do {
                let chain = try await quotes.fetchOptionChain(symbol: ord.symbol, expiration: exp)
                let contracts: [OptionContract]
                if ord.right == .call {
                    contracts = chain.callContracts
                } else if ord.right == .put {
                    contracts = chain.putContracts
                } else {
                    continue
                }
                guard let contract = contracts.first(where: { abs($0.strike - ord.strike) < 0.0001 }) else { continue }
                
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
                
                let isBuy = ord.side == .buy
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
                    } else if ord.tif == .day && !Calendar.current.isDate(ord.placedAt, inSameDayAs: Date()) {
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
    
    /// Fetch current market references (bid/ask/mid) for a specific option contract.
    /// Uses the monitor's configured QuoteService.
    func fetchMarketReferences(symbol: String, expiration: Date, isCall: Bool, strike: Double) async throws -> (bid: Double?, ask: Double?, mid: Double?) {
#if DEBUG
        let nowCheck = Date()
        let expCheckStr = DateFormatter.localizedString(from: expiration, dateStyle: .short, timeStyle: .none)
        let secondsToExp = Int(expiration.timeIntervalSince(nowCheck))
        dlog("[OrderMonitor] validate expiration: exp=\(expCheckStr) secondsToExp=\(secondsToExp) isPast=\(expiration < nowCheck)")
#endif
        
#if DEBUG
        let expLog = DateFormatter.localizedString(from: expiration, dateStyle: .short, timeStyle: .none)
        dlog("[OrderMonitor] fetchMarketReferences symbol=\(symbol) exp=\(expLog) isCall=\(isCall) strike=\(strike)")
#endif
        
        let chain = try await quotes.fetchOptionChain(symbol: symbol, expiration: expiration)
        
#if DEBUG
        let countCalls = chain.callContracts.count
        let countPuts = chain.putContracts.count
        dlog("[OrderMonitor] chain counts: calls=\(countCalls) puts=\(countPuts)")
#endif
        
        let contracts: [OptionContract] = isCall ? chain.callContracts : chain.putContracts
        
#if DEBUG
        let side = isCall ? "call" : "put"
        dlog("[OrderMonitor] contracts empty for side=\(side)")
#endif
        
        guard let contract = contracts.first(where: { abs($0.strike - strike) < 0.0001 }) else {
#if DEBUG
            let sample = contracts.prefix(5).map { String(format: "%.2f", $0.strike) }.joined(separator: ", ")
            dlog("[OrderMonitor] contract not found for strike=\(strike). sample strikes= [\(sample)]")
#endif
            return (nil, nil, nil)
        }
        
        let bid = contract.bid
        let ask = contract.ask
        let last = contract.last
        
#if DEBUG
        dlog("[OrderMonitor] contract quotes bid=\(String(describing: bid)) ask=\(String(describing: ask)) last=\(String(describing: last))")
#endif
        
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
        
#if DEBUG
        dlog("[OrderMonitor] computed mid=\(String(describing: mid))")
#endif
        
        return (bid, ask, mid)
    }
}

