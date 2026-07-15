import SwiftUI

struct BridgePalette {
    let night: Color
    let wine: Color
    let accent: Color
    let copper: Color
    let text: Color
    let surface: Color
    let elevated: Color
    let deep: Color

    static func palette(for theme: AppColorTheme) -> BridgePalette {
        switch theme {
        case .darkroomOrange:
            BridgePalette(night: Color(hex: 0x0E090C), wine: Color(hex: 0x35140F), accent: Color(hex: 0xFF7133), copper: Color(hex: 0xB95732), text: Color(hex: 0xFFF7F1), surface: Color(hex: 0x181015), elevated: Color(hex: 0x211419), deep: Color(hex: 0x08070A))
        case .nikonYellow:
            BridgePalette(night: Color(hex: 0x0B0B0B), wine: Color(hex: 0x252107), accent: Color(hex: 0xFFD400), copper: Color(hex: 0xA88B00), text: Color(hex: 0xF7F7F2), surface: Color(hex: 0x181818), elevated: Color(hex: 0x242424), deep: Color(hex: 0x050505))
        case .professionalGray:
            BridgePalette(night: Color(hex: 0x101214), wine: Color(hex: 0x24272B), accent: Color(hex: 0xD8A64A), copper: Color(hex: 0x8B7449), text: Color(hex: 0xF3F4F5), surface: Color(hex: 0x1A1D20), elevated: Color(hex: 0x24282C), deep: Color(hex: 0x090A0C))
        case .deepBlue:
            BridgePalette(night: Color(hex: 0x07111C), wine: Color(hex: 0x0D2941), accent: Color(hex: 0x49AFFF), copper: Color(hex: 0x236D9E), text: Color(hex: 0xF1F8FF), surface: Color(hex: 0x0E1B28), elevated: Color(hex: 0x14283A), deep: Color(hex: 0x030A11))
        }
    }
}

private struct BridgePaletteKey: EnvironmentKey {
    static let defaultValue = BridgePalette.palette(for: .darkroomOrange)
}

extension EnvironmentValues {
    var bridgePalette: BridgePalette {
        get { self[BridgePaletteKey.self] }
        set { self[BridgePaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct BridgeCardModifier: ViewModifier {
    @Environment(\.bridgePalette) private var palette
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(palette.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.text.opacity(0.09)))
    }
}

extension View {
    func bridgeCard() -> some View { modifier(BridgeCardModifier()) }
}

struct ActivityPill: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 9) {
                if model.isBusy { ProgressView().tint(palette.accent).controlSize(.small) }
                else { Image(systemName: icon).foregroundStyle(palette.accent) }
                Text(notice).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.text.opacity(0.82))
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal).padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var icon: String {
        if case .error = model.workflow { return "exclamationmark.triangle.fill" }
        return model.isConnected ? "checkmark.circle.fill" : "info.circle.fill"
    }
}
