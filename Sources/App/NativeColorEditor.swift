// SPDX-License-Identifier: MIT
import SwiftUI

/// An original host-local palette; it never opens a remote picker or eyedropper.
struct NativeColorEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let save: (String) -> Bool
    @State private var hex: String
    @State private var rgb: RGBColor
    @State private var hsv: HSVColor
    @State private var precise = false
    @State private var saveFailed = false

    private let swatches: [(String, String)] = [
        ("淡粉", "#F6D6DF"), ("玫瑰", "#D990A5"), ("红", "#E65353"), ("橙", "#F49A52"),
        ("淡黄", "#F7E59A"), ("绿", "#6DAF80"), ("青", "#53B4B0"), ("蓝", "#1264D8"),
        ("淡蓝", "#BEDCF4"), ("紫", "#9A7BC0"), ("淡紫", "#DED0EF"), ("奶油", "#F4EADC"),
        ("白", "#FFFFFF"), ("浅灰", "#D1D1D6"), ("深灰", "#292327"), ("黑", "#000000")
    ]

    init(title: String, initialHex: String, save: @escaping (String) -> Bool) {
        self.title = title
        self.save = save
        let initial = RGBColor(hex: initialHex) ?? RGBColor(red: 0, green: 0, blue: 0)
        _rgb = State(initialValue: initial)
        _hsv = State(initialValue: HSVColor(rgb: initial))
        _hex = State(initialValue: String(initial.hex.dropFirst()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color(rgb))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.secondary, lineWidth: 1))
                        .frame(height: 52)
                        .accessibilityLabel("颜色预览")
                        .accessibilityValue(rgb.hex)
                        .accessibilityIdentifier("NativeColorPreview")
                } header: { Text("当前颜色") }
                Section("色盘") {
                    saturationBrightnessPlane
                    hueStrip
                    adjustment("饱和度", key: \.saturation, id: "NativeColorSaturation")
                    adjustment("明度", key: \.brightness, id: "NativeColorBrightness")
                }
                Section("常用颜色") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                        ForEach(swatches, id: \.1) { name, value in
                            Button { if let selected = RGBColor(hex: value) { selectRGB(selected) } } label: {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(color(RGBColor(hex: value)!))
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.secondary, lineWidth: 1))
                                    .overlay {
                                        if rgb.hex == value {
                                            Image(systemName: "checkmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.black, .white)
                                        }
                                    }
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(name)
                            .accessibilityValue(value)
                            .accessibilityAddTraits(rgb.hex == value ? .isSelected : [])
                            .accessibilityIdentifier("NativeColorSwatch" + String(value.dropFirst()))
                        }
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: $precise) {
                        TextField("例如 1264D8", text: Binding(get: { hex }, set: { value in
                            hex = value
                            saveFailed = false
                            if let parsed = RGBColor(hex: value) { updateRGB(parsed) }
                        }))
                        .font(.body.monospaced())
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityLabel("十六进制颜色")
                        .accessibilityIdentifier("NativeColorHex")
                        Text(RGBColor(hex: hex) == nil ? "请输入 6 位十六进制颜色，可带一个 #。" : rgb.hex)
                            .font(.caption)
                            .accessibilityIdentifier("NativeColorValidation")
                        channel("红", \.red, "R")
                        channel("绿", \.green, "G")
                        channel("蓝", \.blue, "B")
                    } label: { Text("精确颜色（可选）").accessibilityIdentifier("NativeColorPrecise") }
                }
                if saveFailed {
                    Text("颜色未能保存，请重试。")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("NativeColorSaveError")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 16) {
                    Button { dismiss() } label: {
                        Text("取消").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(AzkiButtonStyle(id: "color.cancel"))
                    .accessibilityIdentifier("NativeColorCancel")
                    Button {
                        guard let parsed = RGBColor(hex: hex) else { return }
                        if save(parsed.hex) { dismiss() } else { saveFailed = true }
                    } label: {
                        Text("完成").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(AzkiButtonStyle(id: "color.save"))
                    .disabled(RGBColor(hex: hex) == nil)
                    .accessibilityIdentifier("NativeColorSave")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(uiColor: .systemBackground))
            }
        }
    }

    private var saturationBrightnessPlane: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [.white, color(HSVColor(hue: hsv.hue, saturation: 1, brightness: 1).rgb)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                Circle().stroke(.black, lineWidth: 4).overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 20, height: 20)
                    .position(x: marker(hsv.saturation, length: geometry.size.width),
                              y: marker(1 - hsv.brightness, length: geometry.size.height))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                hsv.saturation = unit(gesture.location.x / max(1, geometry.size.width))
                hsv.brightness = 1 - unit(gesture.location.y / max(1, geometry.size.height))
                selectHSV()
            })
        }
        .frame(height: 176)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("饱和度和明度色盘")
        .accessibilityValue(rgb.hex)
        .accessibilityHint("使用下方饱和度和明度滑块调整颜色")
        .accessibilityIdentifier("NativeColorPlane")
    }

    private var hueStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("色相").font(.subheadline)
            GeometryReader { geometry in
                ZStack {
                    LinearGradient(colors: (0...6).map { color(HSVColor(hue: Double($0) / 6, saturation: 1, brightness: 1).rgb) }, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 24).clipShape(Capsule())
                    Circle().fill(color(HSVColor(hue: hsv.hue, saturation: 1, brightness: 1).rgb))
                        .overlay(Circle().stroke(.black, lineWidth: 4).overlay(Circle().stroke(.white, lineWidth: 2)))
                        .frame(width: 28, height: 28)
                        .position(x: marker(hsv.hue, length: geometry.size.width, inset: 15), y: 22)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    hsv.hue = unit(gesture.location.x / max(1, geometry.size.width))
                    selectHSV()
                })
            }
            .frame(height: 44)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("色相")
        .accessibilityValue("\(Int((hsv.hue * 360).rounded())) 度")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: hsv.hue = unit(hsv.hue + 1 / 36)
            case .decrement: hsv.hue = unit(hsv.hue - 1 / 36)
            @unknown default: return
            }
            selectHSV()
        }
        .accessibilityIdentifier("NativeColorHue")
    }

    private func adjustment(_ name: String, key: WritableKeyPath<HSVColor, Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.subheadline)
            Slider(value: Binding(get: { hsv[keyPath: key] }, set: { hsv[keyPath: key] = $0; selectHSV() }), in: 0...1)
                .frame(minHeight: 44)
                .accessibilityLabel(name)
                .accessibilityValue("\(Int((hsv[keyPath: key] * 100).rounded()))%")
                .accessibilityIdentifier(id)
        }
    }

    private func channel(_ name: String, _ key: WritableKeyPath<RGBColor, UInt8>, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(name) · \(rgb[keyPath: key])").monospacedDigit()
            Slider(value: Binding(get: { Double(rgb[keyPath: key]) }, set: { value in
                var selected = rgb
                selected[keyPath: key] = UInt8(max(0, min(255, value.rounded())))
                selectRGB(selected)
            }), in: 0...255, step: 1)
            .frame(minHeight: 44)
            .accessibilityLabel(name)
            .accessibilityValue(String(rgb[keyPath: key]))
            .accessibilityIdentifier("NativeColor" + id)
        }
    }

    private func updateRGB(_ selected: RGBColor) {
        rgb = selected
        let converted = HSVColor(rgb: selected)
        // Gray/black has no defined hue: retain the hue the user last selected.
        hsv = HSVColor(hue: converted.saturation == 0 ? hsv.hue : converted.hue,
                       saturation: converted.saturation, brightness: converted.brightness)
    }
    private func selectRGB(_ selected: RGBColor) {
        updateRGB(selected)
        hex = String(selected.hex.dropFirst())
        saveFailed = false
    }
    private func selectHSV() {
        rgb = hsv.rgb
        hex = String(rgb.hex.dropFirst())
        saveFailed = false
    }
    private func unit(_ value: Double) -> Double { max(0, min(1, value)) }
    private func marker(_ value: Double, length: Double, inset: Double = 12) -> Double { max(inset, min(length - inset, value * length)) }
    private func color(_ value: RGBColor) -> Color {
        Color(.sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255, opacity: 1)
    }
}
