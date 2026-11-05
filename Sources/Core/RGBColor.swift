// SPDX-License-Identifier: MIT
import Foundation

/// Opaque sRGB bytes. Parsing never uses floating-point Color conversion.
public struct RGBColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let bytes = Array(digits.utf8)
        guard bytes.count == 6,
              bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt32(digits, radix: 16) else { return nil }
        red = UInt8((value >> 16) & 255)
        green = UInt8((value >> 8) & 255)
        blue = UInt8(value & 255)
    }
    public var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
}

/// HSV selection coordinates in 0...1. Conversion rounds once to opaque sRGB bytes.
/// Hue 1 is the red endpoint of the hue strip, equivalent to hue 0.
public struct HSVColor: Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = Self.unit(hue)
        self.saturation = Self.unit(saturation)
        self.brightness = Self.unit(brightness)
    }

    public init(rgb: RGBColor) {
        let r = Double(rgb.red) / 255, g = Double(rgb.green) / 255, b = Double(rgb.blue) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let delta = maximum - minimum
        brightness = maximum
        saturation = maximum == 0 ? 0 : delta / maximum
        if delta == 0 { hue = 0 }
        else {
            let sector: Double
            if maximum == r { sector = (g - b) / delta }
            else if maximum == g { sector = (b - r) / delta + 2 }
            else { sector = (r - g) / delta + 4 }
            let normalized = sector / 6
            hue = normalized < 0 ? normalized + 1 : normalized
        }
    }

    public var rgb: RGBColor {
        let h = Self.unit(hue) * 6, s = Self.unit(saturation), v = Self.unit(brightness)
        let chroma = v * s
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - chroma
        let components: (Double, Double, Double)
        switch h {
        case 0..<1: components = (chroma, x, 0)
        case 1..<2: components = (x, chroma, 0)
        case 2..<3: components = (0, chroma, x)
        case 3..<4: components = (0, x, chroma)
        case 4..<5: components = (x, 0, chroma)
        default: components = (chroma, 0, x)
        }
        func byte(_ component: Double) -> UInt8 { UInt8((Self.unit(component + m) * 255).rounded()) }
        return RGBColor(red: byte(components.0), green: byte(components.1), blue: byte(components.2))
    }

    private static func unit(_ value: Double) -> Double { value.isFinite ? max(0, min(1, value)) : 0 }
}

extension RGBColor {
    /// WCAG relative luminance for opaque sRGB, after decoding its transfer curve.
    public var relativeLuminance: Double {
        func linear(_ byte: UInt8) -> Double {
            let component = Double(byte) / 255
            return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Chooses the higher-contrast opaque black/white foreground for this background.
    /// Translucent materials must first determine their effective background color.
    public var readableForeground: RGBColor {
        let luminance = relativeLuminance
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast
            ? RGBColor(red: 0, green: 0, blue: 0)
            : RGBColor(red: 255, green: 255, blue: 255)
    }
}
