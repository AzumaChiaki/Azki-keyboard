// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit

private enum TestReturn: String, CaseIterable {
    case standard = "换行", done = "完成", search = "搜索", go = "前往", send = "发送"
    var value: UIReturnKeyType {
        switch self { case .standard: return .default; case .done: return .done; case .search: return .search; case .go: return .go; case .send: return .send }
    }
}

/// Diagnostics for automated tests. Debug builds show them only when asked to,
/// and Release builds never do.
enum AzkiQA {
    static var enabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-AzkiQA")
#else
        false
#endif
    }
}

enum InputTestFocusTarget: Hashable {
    case textView, textField
}

struct InputTestView: View {
    var onFocusChange: (InputTestFocusTarget, Bool) -> Void = { _, _ in }
    @EnvironmentObject private var settings: AzkiSettings
    @State private var text = ""
    @State private var field = ""
    @State private var returnType: TestReturn = .standard
    @EnvironmentObject private var windowState: AzkiWindowState
    var body: some View {
        AzkiCard(title: "语言") { LanguageChoices() }
        AzkiCard(title: "试用") {
            Text("点按输入区，再用地球键选择 Azki输入法。").font(.callout).foregroundStyle(.secondary)
            NativeTextView(text: $text, returnType: returnType.value, onFocusChange: { onFocusChange(.textView, $0) })
                .frame(height: 156)
                .background(ContinuousRoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .tertiarySystemFill)))
                .id(InputTestFocusTarget.textView)
            NativeTextField(text: $field, returnType: returnType.value, onFocusChange: { onFocusChange(.textField, $0) })
                .frame(height: 44)
                .id(InputTestFocusTarget.textField)
            AzkiButton(id: "clear", title: "清空输入", systemImage: "xmark.circle") { text = ""; field = "" }
            if AzkiQA.enabled { ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(TestReturn.allCases, id: \.self) { item in
                        AzkiButton(id: "returnType.\(item.rawValue)", title: item.rawValue,
                                   systemImage: returnType == item ? "checkmark" : nil) { returnType = item }
                            .frame(minWidth: 74)
                    }
                }
            } }
        }
        IntelliSenseView()
        if AzkiQA.enabled { AzkiCard(title: "窗口与折叠状态") {
            Text(windowState.diagnostic).font(.system(.caption, design: .monospaced)).accessibilityIdentifier("WindowDiagnostics")
            Text(windowState.hinge).font(.system(.caption, design: .monospaced)).accessibilityIdentifier("HingeDiagnostics")
            if #available(iOS 18.0, *) { NativeNavigationDiagnostics() }
            Text("\(AzkiSettings.sharedContainerAvailable ? "共享容器可用" : "共享容器不可用，当前使用独立本地存储")")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("SharedContainerStatus")
        } }
    }
}

private struct NativeTextView: UIViewRepresentable {
    @Binding var text: String
    let returnType: UIReturnKeyType
    let onFocusChange: (Bool) -> Void
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.accessibilityIdentifier = "NativeInput"
        view.accessibilityLabel = "输入测试文本"
        view.autocorrectionType = .no
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            let old = uiView.selectedRange
            uiView.text = text
            uiView.selectedRange = NSRange(location: min(old.location, (text as NSString).length), length: 0)
        }
        if uiView.returnKeyType != returnType { uiView.returnKeyType = returnType; uiView.reloadInputViews() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeTextView
        init(_ parent: NativeTextView) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.onFocusChange(true) }
        func textViewDidEndEditing(_ textView: UITextView) { parent.onFocusChange(false) }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

private struct NativeTextField: UIViewRepresentable {
    @Binding var text: String
    let returnType: UIReturnKeyType
    let onFocusChange: (Bool) -> Void
    func makeUIView(context: Context) -> UITextField {
        let view = UITextField()
        view.delegate = context.coordinator
        view.borderStyle = .roundedRect
        view.placeholder = "单行输入测试"
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "NativeInputField"
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return view
    }
    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text { uiView.text = text }
        if uiView.returnKeyType != returnType { uiView.returnKeyType = returnType; uiView.reloadInputViews() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeTextField
        init(_ parent: NativeTextField) { self.parent = parent }
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.onFocusChange(true) }
        func textFieldDidEndEditing(_ textField: UITextField) { parent.onFocusChange(false) }
        @objc func changed(_ sender: UITextField) { parent.text = sender.text ?? "" }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    }
}

