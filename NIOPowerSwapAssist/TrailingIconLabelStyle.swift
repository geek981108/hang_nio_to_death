//
//  TraillingIconStyle.swift
//  NIOPowerSwapAssist
//
//  Created by 许懿赫 on 2025/1/3.
//

import Foundation
import SwiftUI


struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.title
            configuration.icon
        }
    }
}


extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: Self { Self() }
}
