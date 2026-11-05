// SPDX-License-Identifier: MIT
import SwiftUI

struct AppearanceView: View {
    @EnvironmentObject private var settings: AzkiSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var selectedID = "a"
    @State private var customID = ""
    @State private var colorEditor: ColorEditRequest?
    private struct ColorEditRequest: Identifiable {
        let id = UUID()
        let title: String
        let initialHex: String
        let save: (String) -> Bool
    }
    private let keyIDs = ["a", "return", "space", "backspace", "language", "symbols", "import", "restore", "color.cancel", "color.save"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
        AzkiCard(title: "主题与材质") {
            HStack {
                theme("跟随系统", .system)
                theme("浅色", .light)
                theme("深色", .dark)
            }
            HStack {
                material("毛玻璃", .frosted)
                material("液态玻璃", .liquidGlass).disabled(!supportsLiquidGlass)
                material("纯色", .solid)
            }
            Toggle("按键震动", isOn: binding(\.keyHaptics)).accessibilityIdentifier("KeyHaptics")
            HStack {
                Text("连续圆角")
                Slider(value: cornerRadiusBinding, in: 0...28, step: 1).accessibilityIdentifier("CornerRadius")
                Text("\(Int(effectiveCornerRadius))").monospacedDigit().frame(width: 28)
            }
        }
        AzkiCard(title: "全局按下颜色") {
            globalColor("按下背景", \.pressedBackground, "GlobalPressedBackground")
            AzkiButton(id: "preview", title: "长按预览键帽颜色", systemImage: "hand.tap", keyboardKeycap: true) {}
        }
        AzkiCard(title: "单个按钮配色") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(keyIDs, id: \.self) { id in
                        AzkiButton(id: "select.\(id)", title: selectedID == id ? "✓ \(buttonName(id))" : buttonName(id)) { selectedID = id }
                            .frame(minWidth: 62)
                    }
                }
            }
            HStack {
                TextField("其他按钮 ID，例如 q / shift", text: $customID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("CustomButtonID")
                AzkiButton(id: "select.custom", title: "选择 ID") {
                    selectedID = customID.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .frame(width: 88)
                .disabled(customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || customID.count > 80)
            }
            overrideColor("浅色背景", \.lightBackground, fallback: isKeyboardKeycap(selectedID) ? "#FFFFFF" : "#F2F2F7", id: "KeyLightBackground")
            overrideColor("深色背景", \.darkBackground, fallback: "#29292D", id: "KeyDarkBackground")
            overrideColor("按下背景", \.pressedBackground, fallback: settings.preferences.pressedBackground, id: "KeyPressedBackground")
            HStack {
                if ["quick", "paste", "phrases"].contains(selectedID) {
                    Text("顶部裸图标不使用按钮底色").font(.caption).foregroundStyle(.secondary)
                } else {
                    AzkiButton(id: selectedID, title: buttonName(selectedID) + " 预览",
                               keyboardKeycap: isKeyboardKeycap(selectedID)) {}
                }
                AzkiButton(id: "reset.\(selectedID)", title: "恢复此键默认") {
                    settings.update { $0.keyOverrides.removeValue(forKey: selectedID) }
                }
            }
        }
        }
        .sheet(item: $colorEditor) { request in
            NativeColorEditor(title: request.title, initialHex: request.initialHex, save: request.save)
        }
    }

    private var effectiveCornerRadius: Double { min(28, max(0, settings.preferences.cornerRadius)) }
    private var cornerRadiusBinding: Binding<Double> {
        Binding(get: { effectiveCornerRadius }, set: { value in
            settings.update { $0.cornerRadius = min(28, max(0, value)) }
        })
    }

    private func isKeyboardKeycap(_ id: String) -> Bool {
        id.count == 1 || id.hasPrefix("symbol_")
            || ["return", "space", "backspace", "language", "symbols", "shift", "globe"].contains(id)
    }

    private func buttonName(_ id: String) -> String {
        switch id {
        case "return": return "换行"
        case "space": return "空格"
        case "backspace": return "删除"
        case "language": return "切换语言"
        case "symbols": return "符号"
        case "import": return "导入词库"
        case "restore": return "恢复词库"
        case "color.cancel": return "取消选色"
        case "color.save": return "保存颜色"
        default: return id
        }
    }

    private var supportsLiquidGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private func material(_ name: String, _ material: ButtonMaterialPreference) -> some View {
        // Show the resolved platform choice even while the stored default is automatic.
        let selected = settings.preferences.buttonMaterial.resolved(supportsLiquidGlass: supportsLiquidGlass) == material
        return AzkiButton(id: "Material.\(material.rawValue)", title: name,
                          systemImage: selected ? "checkmark" : nil) {
            settings.update { $0.buttonMaterial = material }
        }
        .accessibilityValue(selected ? "已选择" : "未选择")
    }

    private func theme(_ name: String, _ theme: AppearanceTheme) -> some View {
        AzkiButton(id: "theme.\(name)", title: name,
                   systemImage: settings.preferences.theme == theme ? "checkmark" : nil) {
            settings.update { $0.theme = theme }
        }
    }
    private func binding<Value>(_ key: WritableKeyPath<AzkiPreferences, Value>) -> Binding<Value> {
        Binding(get: { settings.preferences[keyPath: key] }, set: { value in settings.update { $0[keyPath: key] = value } })
    }
    private func colorRow(_ title: String, value: String, id: String, save: @escaping (String) -> Bool) -> some View {
        Button {
            colorEditor = ColorEditRequest(title: title, initialHex: value, save: save)
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(azkiHex: value) ?? .accentColor)
                    .frame(width: 32, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary, lineWidth: 0.5))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityValue(value)
    }
    private func globalColor(_ title: String, _ key: WritableKeyPath<AzkiPreferences, String>, _ id: String) -> some View {
        colorRow(title, value: settings.preferences[keyPath: key], id: id) { value in
            settings.savePreferences { $0[keyPath: key] = value }
        }
    }
    private func overrideColor(_ title: String, _ key: WritableKeyPath<ButtonColors, String?>, fallback: String, id: String) -> some View {
        let targetID = selectedID
        return colorRow(title, value: settings.preferences.keyOverrides[targetID]?[keyPath: key] ?? fallback, id: id) { value in
            settings.savePreferences {
                var colors = $0.keyOverrides[targetID] ?? ButtonColors()
                colors[keyPath: key] = value
                $0.keyOverrides[targetID] = colors
            }
        }
    }
}
