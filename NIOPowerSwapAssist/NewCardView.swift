//
//  NewCardView.swift
//  NIOPowerSwapAssist
//
//  Created by GitHub Copilot on 2025/1/2.
//

import SwiftUI

struct NewCardView: View {
    let batteryModel: BatteryModel
    
    var progressValue: Double {
        let value = Double(batteryModel.batteryCharingProgress.replacingOccurrences(of: "%", with: "")) ?? 0
        return value / 100.0
    }
    
    var statusColor: Color {
        if batteryModel.batteryOccupied {
            return .red
        } else if progressValue >= 0.9 {
            return .green
        } else {
            return .orange
        }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Slot Indicator
            ZStack {
                Circle()
                    .strokeBorder(statusColor, lineWidth: 3)
                    .frame(width: 44, height: 44)
                
                Text("\(batteryModel.batterySlotID)")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                // Top Row: Type and Status
                HStack {
                    Text(batteryModel.batteryType)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if batteryModel.batteryOccupied {
                        StatusBadge(text: "Occupied", color: .red)
                    } else if progressValue >= 0.92 {
                        StatusBadge(text: "Ready", color: .green)
                    } else {
                        StatusBadge(text: "Charging", color: .orange)
                    }
                }
                
                // Middle Row: Progress Bar
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 6)
                            
                            Capsule()
                                .fill(statusColor)
                                .frame(width: geometry.size.width * CGFloat(progressValue), height: 6)
                        }
                    }
                    .frame(height: 6)
                    
                    HStack {
                        Text(batteryModel.battetyManufactureTime)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if !batteryModel.batteryOccupied && progressValue < 1.0 {
                            Text("\(batteryModel.batteryCharingRemainingTime) min")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Text(batteryModel.batteryCharingProgress)
                            .font(.caption2)
                            .bold()
                            .foregroundColor(statusColor)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

#Preview {
    NewCardView(batteryModel: BatteryModel.sampleData[0])
}
