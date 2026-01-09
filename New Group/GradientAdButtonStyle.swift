//
//  GradientAdButtonStyle.swift
//  StrikeGold
//
//  Created by Karl Keller on 12/31/25.
//


//
//  Extensions.swift
//  plateWise
//
//  Created by Karl Keller on 9/11/25.
//
import UIKit
import SwiftUI
import SwiftData
import Foundation

extension UIDevice {
    static let type = UIDevice.current.localizedModel
}
extension Array: @retroactive RawRepresentable where Element == String {
       public init?(rawValue: String) {
           guard let data = rawValue.data(using: .utf8),
                 let result = try? JSONDecoder().decode([String].self, from: data)
           else {
               return nil
           }
           self = result
       }

       public var rawValue: String {
           guard let data = try? JSONEncoder().encode(self),
                 let result = String(data: data, encoding: .utf8)
           else {
               return "[]" // Default empty array if encoding fails
           }
           return result
       }
   }
extension Sequence {
    func uniqued<T: Hashable>(by keyPath: KeyPath<Element, T>) -> [Element] {
        var seen = Set<T>()
        return self.filter { element in
            let key = element[keyPath: keyPath]
            if seen.contains(key) {
                return false
            } else {
                seen.insert(key)
                return true
            }
        }
    }
}
extension ModelContext {
    var sqliteCommand: String {
        if let url = container.configurations.first?.url.path(percentEncoded: false) {
            "sqlite3 \"\(url)\""
        } else {
            "No SQLite database found."
        }
    }
}

// MARK: - Numeric helpers

extension Double {
    /// Rounds the double to the specified number of decimal places.
    func rounded(to places: Int) -> Double {
        guard places >= 0 else { return self }
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
struct GradientAdButtonStyle: ButtonStyle {
    // Access the environment to check if the view hierarchy is currently enabled
    @Environment(\.isEnabled) private var isEnabled
    
    var startColor: Color = .cyan
    var endColor: Color = .indigo
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline).bold()
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [startColor, endColor]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: endColor.opacity(0.4), radius: 10, x: 0, y: 10)
            // Apply dimming effect (e.g., reduce opacity) when disabled
            .opacity(isEnabled ? 1.0 : 0.5)
            // Apply a slight scaling effect when pressed for better user feedback
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
