// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit

@MainActor
final class AzkiWindowState: ObservableObject {
    @Published var diagnostic = "等待窗口信息"
    @Published var hinge = "铰链：无可用数据"
    @Published private(set) var hasObservedHinge = false
    @Published private(set) var isUnfolded = false
    @Published var isPortrait = true
    let isTablet = UIDevice.current.userInterfaceIdiom == .pad

    /// A hinged phone keeps its bars at the side, as the system does, except opened out
    /// and held upright, where a bottom bar fits.
    var prefersSidebar: Bool { hasObservedHinge && !(isPortrait && isUnfolded) }

    func receiveHinge(_ text: String, available: Bool, unfolded: Bool = false) {
        hinge = text
        isUnfolded = unfolded
        // A closed hinge is still a hinged device. Leaving a hierarchy must not
        // make this window briefly switch navigation back to a bottom tab bar.
        if available { hasObservedHinge = true }
    }
}

/// Attached to the root window hierarchy, independently of the selected tab.
struct WindowProbe: UIViewRepresentable {
    let state: AzkiWindowState

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.report = { [weak state] value, portrait in
            DispatchQueue.main.async {
                state?.diagnostic = value
                if state?.isPortrait != portrait { state?.isPortrait = portrait }
            }
        }
        view.reportHinge = { [weak state] value, available, unfolded in
            DispatchQueue.main.async { state?.receiveHinge(value, available: available, unfolded: unfolded) }
        }
        if #available(iOS 27.1, *) {
            view.addInteraction(UIHingeInteraction { [weak view] _, update in
                guard let hinge = update.hinge else {
                    view?.reportHinge?("铰链：此窗口无可用数据", false, false)
                    return
                }
                let status: String
                switch hinge.status {
                case .closed: status = "closed"
                case .partiallyOpen: status = "partiallyOpen"
                case .fullyOpen: status = "fullyOpen"
                case .unknown: status = "unknown"
                @unknown default: status = "future"
                }
                let unfolded = hinge.status == .fullyOpen || hinge.status == .partiallyOpen
                view?.reportHinge?(String(format: "UIHinge %@ / %.3f rad", status, hinge.angle), true, unfolded)
            })
        } else {
            view.reportHinge?("UIHinge 需要 iOS 27.1 或更高版本", false, false)
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) { uiView.publish() }

    final class ProbeView: UIView {
        var report: ((String, Bool) -> Void)?
        var reportHinge: ((String, Bool, Bool) -> Void)?
        private var previous = ""

        override func didMoveToWindow() { super.didMoveToWindow(); publish() }
        override func layoutSubviews() { super.layoutSubviews(); publish() }
        func publish() {
            guard let window, let scene = window.windowScene else { return }
            let screen = window.screen.bounds.size
            let size = window.bounds.size
            let orientation = scene.interfaceOrientation.isLandscape ? "landscape" : "portrait"
            let value = String(format: "window %.0f × %.0f pt\nscreen %.0f × %.0f pt · %@", size.width, size.height, screen.width, screen.height, orientation)
            if value != previous { previous = value; report?(value, size.height >= size.width) }
        }
    }
}

@available(iOS 18.0, *)
struct NativeNavigationDiagnostics: View {
    @EnvironmentObject private var windowState: AzkiWindowState
    @Environment(\.tabBarPlacement) private var placement
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var placementName: String {
        if placement == .sidebar { return "sidebar" }
        if placement == .bottomBar { return "bottomBar" }
        if placement == .topBar { return "topBar" }
        if placement == .ornament { return "ornament" }
        if placement == .pageIndicator { return "pageIndicator" }
        return "unavailable"
    }

    var body: some View {
        Text("导航请求 \(windowState.prefersSidebar ? "sidebar" : "tabBar") / 系统呈现 \(placementName)")
            .font(.system(.caption, design: .monospaced))
            .accessibilityIdentifier("NavigationPlacement")
        Text("页面宽度 \(horizontalSizeClass == .regular ? "regular" : "compact")")
            .font(.system(.caption, design: .monospaced))
            .accessibilityIdentifier("PageHorizontalSizeClass")
        if #available(iOS 27.0, *) { NativeSidebarAvailability() }
    }
}

@available(iOS 27.0, *)
private struct NativeSidebarAvailability: View {
    @Environment(\.isTabViewSidebarAvailable) private var available
    var body: some View {
        Text(available ? "系统侧栏可用" : "当前窗口由系统适配导航布局")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("SidebarAvailability")
    }
}
