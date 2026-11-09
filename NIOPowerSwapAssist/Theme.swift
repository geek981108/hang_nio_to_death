//
//  Theme.swift
//  NIOPowerSwapAssist
//
//  Created by 许懿赫 on 2025/1/2.
//

import Foundation
import SwiftUI

enum AppPalette {
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
        : UIColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1) })
    static let blue = adaptive(
        light: UIColor(red: 0.28, green: 0.43, blue: 0.66, alpha: 1),
        dark: UIColor(red: 0.62, green: 0.74, blue: 0.90, alpha: 1))
    static let green = adaptive(
        light: UIColor(red: 0.19, green: 0.48, blue: 0.34, alpha: 1),
        dark: UIColor(red: 0.52, green: 0.79, blue: 0.62, alpha: 1))
    static let amber = adaptive(
        light: UIColor(red: 0.65, green: 0.38, blue: 0.17, alpha: 1),
        dark: UIColor(red: 0.91, green: 0.69, blue: 0.41, alpha: 1))
    static let violet = adaptive(
        light: UIColor(red: 0.49, green: 0.43, blue: 0.65, alpha: 1),
        dark: UIColor(red: 0.75, green: 0.66, blue: 0.90, alpha: 1))
    static let graphite = adaptive(
        light: UIColor(red: 0.18, green: 0.22, blue: 0.29, alpha: 1),
        dark: UIColor(red: 0.75, green: 0.80, blue: 0.87, alpha: 1))
    static let stationNight = Color(red: 0.18, green: 0.22, blue: 0.29)
    static let climate = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.19, green: 0.16, blue: 0.13, alpha: 1)
        : UIColor(red: 0.97, green: 0.92, blue: 0.84, alpha: 1) })

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

enum Theme: String {
    case bubblegum
    case buttercup
    case indigo
    case lavender
    case magenta
    case navy
    case orange
    case oxblood
    case periwinkle
    case poppy
    case purple
    case seafoam
    case sky
    case tan
    case teal
    case yellow

    var accentColor: Color {
        switch self {
        case .bubblegum, .buttercup, .lavender, .orange, .periwinkle, .poppy, .seafoam, .sky, .tan, .teal, .yellow: return .black
        case .indigo, .magenta, .navy, .oxblood, .purple: return .white
        }
    }
    var mainColor: Color {
        Color(rawValue)
    }
}
