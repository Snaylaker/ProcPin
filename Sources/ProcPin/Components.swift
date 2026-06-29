import SwiftUI

// MARK: - Status dot

struct StatusDot: View {
    let running: Bool
    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
            .overlay(
                Circle().stroke(running ? Color.green.opacity(0.35) : .clear, lineWidth: 4)
            )
    }
}

// MARK: - Role / project badge

struct Badge: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Meter bar (generic usage bar, CodexBar-style)

/// A thin rounded usage bar that fills left-to-right.
struct MeterBar: View {
    let fraction: CGFloat   // 0...1
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Capacity bar (CPU)

/// A compact horizontal bar showing CPU load, with a numeric label.
struct CapacityBar: View {
    let cpuPercent: Double      // 0...(multicore can exceed 100)
    let memoryBytes: UInt64?
    var width: CGFloat = 56

    private var fraction: CGFloat {
        min(max(cpuPercent / 100.0, 0), 1)
    }
    private var tint: Color {
        switch cpuPercent {
        case ..<40: return .green
        case 40..<80: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            MeterBar(fraction: fraction, tint: tint, height: 5)
                .frame(width: width)
            HStack(spacing: 4) {
                Text(Format.cpu(cpuPercent))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                if let mem = memoryBytes {
                    Text("·").foregroundStyle(.tertiary).font(.system(size: 9))
                    Text(Format.memory(mem))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: width)
    }
}

// MARK: - Icon button used for row actions

struct IconButton: View {
    let systemName: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(hovering ? tint.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
