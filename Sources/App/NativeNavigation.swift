// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit

private enum HomePage: String, CaseIterable {
    case input = "输入", dictionary = "词库", phrases = "短语", appearance = "外观", about = "说明"

    var symbol: String {
        switch self {
        case .input: return "keyboard"
        case .dictionary: return "book.closed"
        case .phrases: return "text.bubble"
        case .appearance: return "paintpalette"
        case .about: return "info.circle"
        }
    }
}

struct AzkiHomeView: View {
    @State private var page: HomePage = .input
    @StateObject private var windowState = AzkiWindowState()

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                NativeAzkiTabs(selection: $page)
            } else {
                TabView(selection: $page) {
                    ForEach(HomePage.allCases, id: \.self) { destination in
                        AzkiPage(destination: destination)
                            .tabItem {
                                Label(destination.rawValue, systemImage: destination.symbol)
                                    .accessibilityIdentifier("tab.\(destination.rawValue)")
                            }
                            .tag(destination)
                    }
                }
            }
        }
        .environmentObject(windowState)
        .background(WindowProbe(state: windowState).allowsHitTesting(false).accessibilityHidden(true))
    }
}

@available(iOS 18.0, *)
private struct NativeAzkiTabs: View {
    @Binding var selection: HomePage
    @Environment(\.horizontalSizeClass) private var actualHorizontalSizeClass
    @EnvironmentObject private var windowState: AzkiWindowState

    var body: some View {
        if windowState.isTablet && !windowState.hasObservedHinge {
            // Only the tab container adopts compact navigation. Page content
            // keeps the real outer size class; never override the window trait.
            tabs
                .tabViewStyle(.tabBarOnly)
                .environment(\.horizontalSizeClass, .compact)
        } else if #available(iOS 27.0, *) {
            tabs
                .tabViewStyle(.sidebarAdaptable)
                .defaultTabBarPlacement(windowState.prefersSidebar ? .sidebar : .tabBar)
        } else {
            tabs
                .tabViewStyle(.sidebarAdaptable)
                .defaultAdaptableTabBarPlacement(windowState.prefersSidebar ? .sidebar : .tabBar)
        }
    }

    /// On a hinged phone the system puts the status bar and `TabView`'s own bar in a column
    /// at the side, whatever the size class or tab style. Opened out and upright, a system
    /// `UITabBar` takes its place and drives the same `TabView`, so pages keep their edits.
    private var usesBottomBar: Bool { windowState.hasObservedHinge && !windowState.prefersSidebar }

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(HomePage.allCases, id: \.self) { destination in
                Tab(destination.rawValue, systemImage: destination.symbol, value: destination) {
                    AzkiPage(destination: destination)
                        .environment(\.horizontalSizeClass, actualHorizontalSizeClass)
                        .toolbar(usesBottomBar ? .hidden : .automatic, for: .tabBar)
                }.accessibilityIdentifier("tab.\(destination.rawValue)")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if usesBottomBar { SystemTabBar(selection: $selection) }
        }
    }
}

/// The system tab bar on its own, for where `TabView` won't place it at the bottom.
private struct SystemTabBar: UIViewRepresentable {
    @Binding var selection: HomePage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        bar.items = HomePage.allCases.enumerated().map { index, page in
            let item = UITabBarItem(title: page.rawValue, image: UIImage(systemName: page.symbol), tag: index)
            item.accessibilityIdentifier = "tab.\(page.rawValue)"
            return item
        }
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.select = { selection = HomePage.allCases[$0] }
        bar.selectedItem = HomePage.allCases.firstIndex(of: selection).flatMap { bar.items?[$0] }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITabBar, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: uiView.sizeThatFits(.zero).height)
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var select: (Int) -> Void = { _ in }
        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) { select(item.tag) }
    }
}

/// Each tab owns a stable navigation stack, page identity and scroll position.
private struct AzkiPage: View {
    let destination: HomePage
    @State private var focusedInput: InputTestFocusTarget?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch destination {
                        case .input: InputTestView(onFocusChange: updateInputFocus)
                        case .dictionary: DictionaryView()
                        case .phrases: PhraseEditorView()
                        case .appearance: AppearanceView()
                        case .about: AboutView()
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: focusedInput) { _ in revealFocusedInput(using: proxy) }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    revealFocusedInput(using: proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                    revealFocusedInput(using: proxy)
                }
            }
            .navigationTitle(destination == .input ? "Azki输入法" : destination.rawValue)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func updateInputFocus(_ target: InputTestFocusTarget, _ editing: Bool) {
        if editing { focusedInput = target }
        else if focusedInput == target { focusedInput = nil }
    }

    private func revealFocusedInput(using proxy: ScrollViewProxy) {
        guard destination == .input, let target = focusedInput else { return }
        // Let SwiftUI finish the keyboard safe-area layout before moving the
        // existing input view. Its identity, first responder and text stay intact.
        DispatchQueue.main.async {
            guard focusedInput == target else { return }
            proxy.scrollTo(target, anchor: .top)
        }
    }
}
