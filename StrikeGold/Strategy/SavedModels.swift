//
//  SavedModels.swift
//  StrikeGold
//
//  Created by Assistant on 1/8/26.
//
import Foundation

struct SavedStrategy: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case singleCall, singlePut, bullCallSpread
    }
    struct SavedLeg: Codable, Hashable {
        var type: String // "call" or "put"
        var side: String // "long" or "short"
        var strike: Double
        var premium: Double
        var contracts: Int
        var multiplier: Double
    }
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var kind: Kind
    var symbol: String
    var expiration: Date?
    var legs: [SavedLeg]
    var marketPriceAtSave: Double?
    var note: String?
}

final class StrategyStore {
    static let shared = StrategyStore()
    private let key = "saved_strategies_v1"
    func load() -> [SavedStrategy] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedStrategy].self, from: data)) ?? []
    }
    func save(_ strategies: [SavedStrategy]) {
        if let data = try? JSONEncoder().encode(strategies) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    func append(_ strategy: SavedStrategy) {
        var all = load()
        all.append(strategy)
        save(all)
    }
    func remove(id: UUID) {
        var all = load()
        all.removeAll { $0.id == id }
        save(all)
    }
}
