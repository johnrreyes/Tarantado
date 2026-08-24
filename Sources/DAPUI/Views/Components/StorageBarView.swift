import SwiftUI

/// A horizontal used/incoming/free bar, plus a legend line. Used on the
/// Device screen (no incoming bytes) and the Review screen (incoming bytes
/// from the computed plan).
struct StorageBarView: View {
    let breakdown: StorageBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * breakdown.usedFraction)
                        if breakdown.incomingBytes > 0 {
                            Capsule()
                                .fill(breakdown.fits ? Color.green : Color.red)
                                .frame(width: proxy.size.width * breakdown.incomingFraction)
                        }
                    }
                }
            }
            .frame(height: 14)

            HStack(spacing: 16) {
                legendItem(color: .accentColor, text: "\(Formatting.bytes(breakdown.usedBytes)) used")
                if breakdown.incomingBytes > 0 {
                    legendItem(
                        color: breakdown.fits ? .green : .red,
                        text: "\(Formatting.bytes(breakdown.incomingBytes)) incoming"
                    )
                }
                Spacer()
                Text("\(Formatting.bytes(breakdown.resultingFreeBytes)) free")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue(accessibilityValue)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private var accessibilityValue: String {
        var parts = ["\(Formatting.bytes(breakdown.usedBytes)) used of \(Formatting.bytes(breakdown.totalBytes))"]
        if breakdown.incomingBytes > 0 {
            parts.append("\(Formatting.bytes(breakdown.incomingBytes)) incoming")
            parts.append(breakdown.fits ? "fits on device" : "does not fit on device")
        }
        parts.append("\(Formatting.bytes(breakdown.resultingFreeBytes)) free afterward")
        return parts.joined(separator: ", ")
    }
}
