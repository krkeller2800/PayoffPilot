//
//  OptionType.swift
//  PayoffPilot
//
//  Created by Karl Keller on 12/30/25.
//


import Foundation

/// Basic option payoff math for a minimal MVP:
/// - Long Call
/// - Long Put
/// Payoff is at expiration and expressed in dollars (includes multiplier).
enum OptionType: String, CaseIterable, Identifiable {
    case call = "Call"
    case put  = "Put"
    var id: String { rawValue }
}

struct PayoffPoint: Identifiable {
    let id = UUID()
    let underlying: Double
    let profitLoss: Double
}

struct OptionsAnalysis {
    let optionType: OptionType
    let strike: Double
    let premium: Double
    let contracts: Int
    let multiplier: Double

    /// Total premium paid ($)
    var totalDebit: Double {
        premium * Double(contracts) * multiplier
    }

    /// Max loss ($) for long call/put is always the debit.
    var maxLoss: Double {
        -totalDebit
    }

    /// Max gain:
    /// - Call: unlimited
    /// - Put: capped if underlying goes to 0 => (K - premium) * contracts * multiplier
    var maxGain: Double? {
        switch optionType {
        case .call:
            return nil // unlimited
        case .put:
            let perShareMax = max(0, strike - premium) // if S -> 0
            return perShareMax * Double(contracts) * multiplier
        }
    }

    /// Breakeven at expiry:
    /// - Call: K + premium
    /// - Put:  K - premium
    var breakeven: Double {
        switch optionType {
        case .call: return strike + premium
        case .put:  return strike - premium
        }
    }

    /// Payoff at expiry for a given underlying price S.
    func profitLoss(at underlying: Double) -> Double {
        let intrinsicPerShare: Double
        switch optionType {
        case .call:
            intrinsicPerShare = max(0, underlying - strike)
        case .put:
            intrinsicPerShare = max(0, strike - underlying)
        }

        // Long option payoff per share is intrinsic - premium
        let perSharePL = intrinsicPerShare - premium
        return perSharePL * Double(contracts) * multiplier
    }

    /// Generates payoff curve points across a price range.
    /// - Parameters:
    ///   - center: a “current” price used to set a sensible range
    ///   - widthFactor: range half-width = center * widthFactor (e.g. 0.5 => ±50%)
    ///   - steps: number of points
    func payoffCurve(center: Double, widthFactor: Double = 0.5, steps: Int = 80) -> [PayoffPoint] {
        let safeCenter = max(0.01, center)
        let halfWidth = safeCenter * widthFactor
        let minS = max(0, safeCenter - halfWidth)
        let maxS = safeCenter + halfWidth

        let n = max(10, steps)
        let step = (maxS - minS) / Double(n - 1)

        return (0..<n).map { i in
            let s = minS + Double(i) * step
            return PayoffPoint(underlying: s, profitLoss: profitLoss(at: s))
        }
    }
}

/// Convenience formatting helpers
enum OptionsFormat {
    static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
}
/// Side of an option leg
enum OptionSide: String, CaseIterable, Identifiable {
    case long = "Long"
    case short = "Short"
    var id: String { rawValue }
}

/// Represents a single option leg (call/put, long/short)
struct OptionLeg {
    let type: OptionType
    let side: OptionSide
    let strike: Double
    let premium: Double
    let contracts: Int
    let multiplier: Double

    /// Signed premium paid/received for this leg ($)
    var debit: Double {
        let sign: Double = (side == .long) ? 1 : -1
        return premium * sign * Double(contracts) * multiplier
    }

    /// Profit/loss for this leg at expiration for a given underlying price S ($)
    func profitLoss(at underlying: Double) -> Double {
        let intrinsicPerShare: Double
        switch type {
        case .call:
            intrinsicPerShare = max(0, underlying - strike)
        case .put:
            intrinsicPerShare = max(0, strike - underlying)
        }
        let perShare = intrinsicPerShare - premium
        let signedPerShare = (side == .long) ? perShare : -perShare
        return signedPerShare * Double(contracts) * multiplier
    }
}

/// Multi-leg options analysis that sums legs to produce total payoff
struct MultiLegAnalysis {
    let legs: [OptionLeg]

    /// Net debit (positive) or credit (negative)
    var totalDebit: Double {
        legs.reduce(0) { $0 + $1.debit }
    }

    /// Total P/L at expiration for a given underlying price S
    func profitLoss(at underlying: Double) -> Double {
        legs.reduce(0) { $0 + $1.profitLoss(at: underlying) }
    }

    /// Generates payoff curve points across a price range.
    /// - Parameters:
    ///   - center: a “current” price used to set a sensible range
    ///   - widthFactor: range half-width = center * widthFactor (e.g. 0.5 => ±50%)
    ///   - steps: number of points
    func payoffCurve(center: Double, widthFactor: Double = 0.5, steps: Int = 80) -> [PayoffPoint] {
        let safeCenter = max(0.01, center)
        let halfWidth = safeCenter * widthFactor
        let minS = max(0, safeCenter - halfWidth)
        let maxS = safeCenter + halfWidth

        let n = max(10, steps)
        let step = (maxS - minS) / Double(n - 1)

        return (0..<n).map { i in
            let s = minS + Double(i) * step
            return PayoffPoint(underlying: s, profitLoss: profitLoss(at: s))
        }
    }

    /// Derive metrics numerically from a sampled payoff curve around the given center.
    /// This generalizes to arbitrary multi-leg combos.
    func metrics(center: Double) -> (maxLoss: Double, maxGain: Double?, breakeven: Double?) {
        let points = payoffCurve(center: center, widthFactor: 0.8, steps: 200)
        guard points.count >= 3 else { return (0, 0, nil) }

        let ys = points.map { $0.profitLoss }
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0

        // Heuristic for unlimited upside: if max occurs at the upper bound and the slope is positive
        let last = ys[ys.count - 1]
        let prev = ys[ys.count - 2]
        let isIncreasingAtEnd = last > prev + 1e-9
        let isMaxAtEnd = abs(last - maxY) < 1e-9
        let inferredMaxGain: Double? = (isMaxAtEnd && isIncreasingAtEnd) ? nil : maxY

        // Find first sign change crossing for breakeven (linear interpolation)
        var crossing: Double? = nil
        for i in 1..<points.count {
            let y1 = ys[i-1]
            let y2 = ys[i]
            if (y1 <= 0 && y2 >= 0) || (y1 >= 0 && y2 <= 0) {
                let x1 = points[i-1].underlying
                let x2 = points[i].underlying
                let t = y2 - y1
                let x = t == 0 ? x1 : x1 + (x2 - x1) * (-y1) / t
                crossing = x
                break
            }
        }

        return (minY, inferredMaxGain, crossing)
    }
}

