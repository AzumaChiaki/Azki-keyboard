// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit

/// Original wrapper that uses Apple's continuous corner geometry.
struct ContinuousRoundedRectangle: Shape {
    var cornerRadius: CGFloat
    var keyboardKeycap = false

    func path(in rect: CGRect) -> Path {
        // Narrow keycaps retain straight edges. The stored preference is unchanged;
        // only this rendered shape is capped, using Apple's continuous geometry.
        let shortestSide = max(0, min(rect.width, rect.height))
        let radius = keyboardKeycap ? min(max(0, cornerRadius), shortestSide * 0.22) : cornerRadius
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

extension Color {
    init?(azkiHex: String?) {
        guard let input = azkiHex else { return nil }
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }

    var azkiHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return AzkiPreferences.defaultPressedBackground }
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

struct AzkiButton: View {
    let id: String
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var keyboardKeycap = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1).minimumScaleFactor(0.65)
            }
        }
        .buttonStyle(AzkiButtonStyle(id: id, keyboardKeycap: keyboardKeycap))
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
    }
}

/// Press state for a key whose touches are handled outside its `Button`.
@MainActor
final class KeyPressSignal: ObservableObject {
    @Published var pressed = false
}

struct AzkiButtonStyle: ButtonStyle {
    @EnvironmentObject private var settings: AzkiSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    let id: String
    var minimumHeight: CGFloat = 44
    var horizontalPadding: CGFloat = 10
    var defaultBackground: Color? = nil
    var defaultForeground: Color? = nil
    var keyboardKeycap = false
    @ObservedObject var pressSignal = KeyPressSignal()

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || pressSignal.pressed
        let p = settings.preferences
        let override = p.keyOverrides[id]
        let material = p.buttonMaterial.resolved(supportsLiquidGlass: supportsLiquidGlass,
                                               reduceTransparency: reduceTransparency,
                                               increasedContrast: contrast == .increased)
        let radius = CGFloat(min(28, max(0, p.cornerRadius)))
        let shape = ContinuousRoundedRectangle(cornerRadius: radius, keyboardKeycap: keyboardKeycap)
        let customHex = scheme == .dark ? override?.darkBackground : override?.lightBackground
        let customBackground = Color(azkiHex: customHex)
        let semanticBackground = defaultBackground
        // Only uncustomized light keycaps adopt the white keyboard-key baseline.
        // Semantic action colors and user overrides retain their own tint policy.
        let defaultLightKeycap = keyboardKeycap && scheme == .light
            && customBackground == nil && semanticBackground == nil
        let ordinaryBackground = scheme == .dark
            ? Color(.sRGB, red: 24 / 255, green: 25 / 255, blue: 28 / 255, opacity: 1)
            : (keyboardKeycap ? Color.white : Color(uiColor: .secondarySystemBackground))
        let regularBackground = customBackground ?? semanticBackground ?? ordinaryBackground
        let pressedHex = override?.pressedBackground ?? p.pressedBackground
        let pressedBackground = Color(azkiHex: pressedHex) ?? Color(azkiHex: AzkiPreferences.defaultPressedBackground)!
        let solidForeground = (customBackground ?? semanticBackground).map { readableForeground(for: $0) }
            ?? defaultForeground ?? .primary
        let pressedForeground = Color(azkiHex: (RGBColor(hex: pressedHex)
            ?? RGBColor(hex: AzkiPreferences.defaultPressedBackground)!).readableForeground.hex)!
        // Every keycap follows the selected material at rest, including custom colors
        // and semantic action keys. Glass colors are tints, not exact opaque pixels.
        // Pressed feedback intentionally becomes opaque to preserve the chosen color.
        let usesMaterial = !pressed
        let glass = material == .liquidGlass && usesMaterial
        let frosted = material == .frosted && usesMaterial
        let foreground: Color = glass || frosted ? .primary : solidForeground
        let tint = customBackground ?? semanticBackground
        // White is a native glass tint, not a keyboard-wide background. Its final
        // rendered appearance still depends on the system material and host scene.
        let glassTint = defaultLightKeycap ? Color.white
            : tint?.opacity(scheme == .dark ? 0.12 : 0.16) ?? (scheme == .dark ? Color.black.opacity(0.25) : nil)
        // Keep the system material dominant, especially with a white tint in dark mode.
        let frostedTint = defaultLightKeycap ? Color.white.opacity(0.85)
            : tint?.opacity(scheme == .dark ? 0.12 : 0.16)
                ?? (scheme == .dark ? Color.black.opacity(0.22) : Color.clear)
        let background = pressed ? pressedBackground : regularBackground
        let base = configuration.label
            .font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .foregroundStyle(contrast == .increased ? Color.primary : (pressed ? pressedForeground : foreground))
            .background(shape.fill(
                contrast == .increased ? Color(uiColor: .systemBackground) :
                    ((glass || frosted) ? Color.clear : background)))
            .background {
                if frosted {
                    shape.fill(.regularMaterial)
                        .overlay(shape.fill(frostedTint))
                }
            }
            .contentShape(shape)
        stableGlass(base, active: glass, shape: shape, tint: glassTint)
            .overlay(shape
                .stroke(Color.primary.opacity(contrast == .increased ? 0.8 : (scheme == .dark ? 0.06 : 0.1)),
                        lineWidth: contrast == .increased ? (pressed ? 4 : 2) : 0.5))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            // Going down shows at once. Easing it would be felt as lag on every key.
            .animation(reduceMotion || pressed ? nil : .easeOut(duration: 0.12), value: pressed)
    }

    /// Only opaque colors use numeric contrast. Translucent materials use semantic
    /// foreground styles because their final background depends on the system scene.
    private func readableForeground(for color: Color) -> Color {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .primary }
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        let rgb = RGBColor(red: byte(red), green: byte(green), blue: byte(blue))
        return Color(azkiHex: rgb.readableForeground.hex) ?? .primary
    }

    private var supportsLiquidGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    @ViewBuilder
    private func stableGlass<Content: View>(_ content: Content, active: Bool, shape: ContinuousRoundedRectangle, tint: Color?) -> some View {
        if #available(iOS 26.0, *) {
            // The structure is stable when the preference changes; .identity disables only material.
            // Keep regular glass for keyboard keycaps. App controls use the public
            // clear variant, verified separately in the file-dialog return flow.
            let material = (keyboardKeycap ? Glass.regular : Glass.clear).tint(tint)
            // Keep button contours stable by disabling the interactive glass lens.
            // Material and tint remain, with exact pressed-color feedback and
            // reduced-motion-aware scale.
            content.glassEffect(active ? material.interactive(false) : .identity,
                                in: shape)
        } else {
            content
        }
    }
}
