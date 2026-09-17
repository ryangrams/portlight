import SwiftUI
import PortlightKit

/// The N×N grid motif of a resolution button (2 for HD up to 5 for UHD), drawn in the current foreground.
struct ResolutionGridGlyph: View {
    let side: Int
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 30

    init(side: Int) {
        self.side = max(1, side)
    }

    var body: some View {
        let gap = max(1.5, size * 0.07)
        let corner = max(1, size / CGFloat(side) * 0.18)
        VStack(spacing: gap) {
            ForEach(0..<side, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<side, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(.foreground)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Swatches for the three colour choices: a gradient, a 4×4 palette and four gray bars.
struct ColorModeSwatch: View {
    let mode: ColorMode
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 28

    init(mode: ColorMode) {
        self.mode = mode
    }

    private static let spectrum: [Color] = (0..<7).map { Color(hue: Double($0) / 7, saturation: 0.8, brightness: 0.95) }
    private static let palette: [Color] = [
        (0.90, 0.20, 0.20), (0.95, 0.55, 0.15), (0.98, 0.85, 0.20), (0.45, 0.80, 0.25),
        (0.15, 0.65, 0.45), (0.15, 0.70, 0.80), (0.20, 0.45, 0.90), (0.40, 0.30, 0.85),
        (0.70, 0.30, 0.80), (0.90, 0.35, 0.60), (0.55, 0.35, 0.20), (0.95, 0.95, 0.95),
        (0.70, 0.70, 0.70), (0.45, 0.45, 0.45), (0.22, 0.22, 0.22), (0.05, 0.05, 0.05),
    ].map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    private static let grays: [Double] = [0.12, 0.38, 0.64, 0.90]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        swatch
            .frame(width: height * 1.6, height: height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var swatch: some View {
        switch mode {
        case .full:
            LinearGradient(colors: Self.spectrum, startPoint: .leading, endPoint: .trailing)
        case .color256:
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { column in
                            Rectangle().fill(Self.palette[row * 4 + column])
                        }
                    }
                }
            }
        case .gray16:
            HStack(spacing: 0) {
                ForEach(Self.grays, id: \.self) { white in
                    Rectangle().fill(Color(white: white))
                }
            }
        }
    }
}

/// A large option button's face: glyph, title and detail. Selected is a filled accent tile inside a 2 pt ring
/// (thicker with Increase Contrast) with readable text; unavailable is dimmed.
struct OptionCard<Glyph: View>: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let isAvailable: Bool
    private let glyph: Glyph
    private var a11y = PortlightAccessibility()

    init(title: String, detail: String?, isSelected: Bool, isAvailable: Bool, @ViewBuilder glyph: () -> Glyph) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.isAvailable = isAvailable
        self.glyph = glyph()
    }

    var body: some View {
        VStack(spacing: 6) {
            glyph
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isSelected ? PortlightTheme.onAccent : PortlightTheme.secondaryText)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(isSelected ? PortlightTheme.onAccent : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background { face }
        .opacity(isAvailable ? 1 : 0.4)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var face: some View {
        let outer = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if isSelected {
            ZStack {
                outer.strokeBorder(Color.accentColor, lineWidth: a11y.selectedOutline)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor)
                    .padding(a11y.selectedOutline + 2)
            }
        } else {
            ZStack {
                outer.fill(PortlightTheme.optionFill)
                outer.strokeBorder(Color(uiColor: .separator), lineWidth: a11y.idleOutline)
            }
        }
    }
}
