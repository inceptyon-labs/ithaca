import SwiftUI
import UIKit

enum MainTabItem: Hashable, Identifiable {
    case home
    case library(PlexLibraryType)
    case liveTV
    case downloads
    case discover
    case search
    case settings
    case more

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library(let libraryType):
            libraryType.tabTitle
        case .liveTV:
            "Live TV"
        case .downloads:
            "Downloads"
        case .discover:
            "Discover"
        case .search:
            "Search"
        case .settings:
            "Settings"
        case .more:
            "More"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            "house"
        case .library(let libraryType):
            libraryType.systemImage
        case .liveTV:
            "dot.radiowaves.left.and.right"
        case .downloads:
            "arrow.down.circle"
        case .discover:
            "sparkles"
        case .search:
            "magnifyingglass"
        case .settings:
            "gearshape"
        case .more:
            "ellipsis"
        }
    }
}

struct MainTabIOSShell<Content: View>: View {
    let tabs: [MainTabItem]
    let selection: Binding<MainTabItem>
    let content: (MainTabItem) -> Content

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                Tab(
                    tab.title,
                    systemImage: tab.systemImage,
                    value: tab
                ) {
                    content(tab)
                }
            }
        }
    }
}

struct MainTabTVShell<Content: View>: View {
    let tabs: [MainTabItem]
    let selection: Binding<MainTabItem>
    /// Asked on each Siri Remote Back press at the root of the selected tab
    /// for what it does; `nil` leaves the press to the system. Asked per
    /// press, not passed in as a value, so the state it reads (Home's scroll
    /// position) never re-renders the shell. See `MainTabView.rootBackAction`.
    let rootBackAction: () -> (() -> Void)?
    /// Asked when Select is pressed with focus on the tab bar: what reselecting
    /// the current tab does, or `nil`. See `MainTabView.reselectAction`.
    let reselectAction: () -> (() -> Void)?
    let content: (MainTabItem) -> Content

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                content(tab)
                    // The bar's tint below would otherwise reach every tab's
                    // content, and an explicit tint makes system glass buttons
                    // go white-on-white on focus. Content gets no tint at all.
                    .tint(nil)
                    .background {
                        IthacaTVTabBarTintPin()
                            .frame(width: 0, height: 0)
                    }
                    .tag(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                            .symbolRenderingMode(.monochrome)
                    }
            }
        }
        .tint(Color.ithacaTVTabBarTint)
        .background(Color.ithacaBackground.ignoresSafeArea())
        #if os(tvOS)
        .background {
            IthacaTVRootBackInterceptor(
                resolveAction: rootBackAction,
                resolveReselectAction: reselectAction
            )
                .frame(width: 0, height: 0)
        }
        #endif
    }
}

#if os(tvOS)
/// Zero-size helper that takes the Siri Remote's Back press away from the
/// system at the root of a tab, where tvOS would otherwise leave the app.
///
/// SwiftUI's `onExitCommand` cannot do this: it only fires while focus is in
/// the tab's content, and Back with focus on the tab bar goes straight to the
/// system. A Back-only tap recognizer on the tab bar controller's view sees
/// the press wherever focus is in the shell, tab bar included. Anything
/// presented on top (the player, sheets, menus) lives outside that view, so
/// it never sees their presses.
///
/// The recognizer refuses the press, leaving the system's behaviour intact,
/// whenever there is no action or the selected tab has a pushed screen: the
/// navigation stack's own pop must win there.
///
/// A second recognizer takes Select while focus is on the tab bar, because
/// tvOS's `TabView` never reports a press on the tab that is already selected.
/// It only claims the press when the reselect action has something to do.
private struct IthacaTVRootBackInterceptor: UIViewControllerRepresentable {
    let resolveAction: () -> (() -> Void)?
    let resolveReselectAction: () -> (() -> Void)?

    func makeUIViewController(context: Context) -> IthacaTVRootBackController {
        IthacaTVRootBackController()
    }

    func updateUIViewController(_ uiViewController: IthacaTVRootBackController, context: Context) {
        uiViewController.resolveAction = resolveAction
        uiViewController.resolveReselectAction = resolveReselectAction
        uiViewController.installIfNeeded()
    }
}

private final class IthacaTVRootBackController: UIViewController, UIGestureRecognizerDelegate {
    var resolveAction: (() -> (() -> Void)?)?
    var resolveReselectAction: (() -> (() -> Void)?)?

    private weak var shellTabBarController: UITabBarController?

    private lazy var recognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleBack))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        // Presses only: a tap on the remote's touch surface is not Back.
        recognizer.allowedTouchTypes = []
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var reselectRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleReselect))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        recognizer.allowedTouchTypes = []
        recognizer.delegate = self
        return recognizer
    }()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installIfNeeded()
    }

    /// Attaches the recognizer to the shell's tab bar controller, moving it if
    /// SwiftUI has rebuilt that controller since the last look.
    func installIfNeeded() {
        guard let tabBarController = resolvedTabBarController() else { return }
        guard recognizer.view !== tabBarController.view else { return }
        for recognizer in [recognizer, reselectRecognizer] {
            recognizer.view?.removeGestureRecognizer(recognizer)
            tabBarController.view.addGestureRecognizer(recognizer)
        }
        shellTabBarController = tabBarController
    }

    @objc private func handleBack() {
        resolveAction?()?()
    }

    @objc private func handleReselect() {
        resolveReselectAction?()?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        guard let tabBarController = shellTabBarController,
              tabBarController.presentedViewController == nil else { return false }
        let selected = tabBarController.selectedViewController ?? tabBarController
        if gestureRecognizer === reselectRecognizer {
            return resolveReselectAction?() != nil && isFocusOnTabBar(of: tabBarController, selected: selected)
        }
        guard resolveAction?() != nil else { return false }
        return !Self.hasPushedScreen(in: selected)
    }

    /// Focus is in the shell but outside the selected tab's content: on the
    /// tab bar.
    private func isFocusOnTabBar(of tabBarController: UITabBarController, selected: UIViewController) -> Bool {
        guard let focused = view.window?.windowScene?.focusSystem?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: tabBarController.view) && !focused.isDescendant(of: selected.view)
    }

    /// Whether any navigation stack inside `controller` shows more than its
    /// root. SwiftUI's `NavigationStack` is a `UINavigationController` under
    /// the hood, which also covers `NavigationLink(destination:)` pushes that
    /// never appear in the tab's `NavigationPath`.
    private static func hasPushedScreen(in controller: UIViewController) -> Bool {
        if let navigationController = controller as? UINavigationController,
           navigationController.viewControllers.count > 1 {
            return true
        }
        return controller.children.contains { hasPushedScreen(in: $0) }
    }

    private func resolvedTabBarController() -> UITabBarController? {
        // The helper sits beside the `TabView`, not inside it, so the tab bar
        // controller is not in its parent chain. Search from the window root.
        guard let root = view.window?.rootViewController else { return nil }
        return Self.firstTabBarController(in: root)
    }

    private static func firstTabBarController(in controller: UIViewController) -> UITabBarController? {
        if let tabBarController = controller as? UITabBarController {
            return tabBarController
        }
        for child in controller.children {
            if let tabBarController = firstTabBarController(in: child) {
                return tabBarController
            }
        }
        return nil
    }
}
#endif

/// Zero-size helper that keeps the tvOS tab bar tinted with
/// `Color.ithacaTVTabBarTint`.
///
/// SwiftUI's `.tint` on the tvOS `TabView` is not sticky: returning from a
/// pushed detail screen or from the full-screen player can leave the real
/// `UITabBar` back on the inherited window tint. When the global accent was
/// still Sunset Coral that painted the selected tab item coral. Pinning the
/// bar's own `tintColor` makes it explicit, so it no longer inherits, and
/// re-pinning on every shell update repairs it if SwiftUI overwrites it again.
/// A zero-size sentinel view inside the bar catches every later tint change
/// UIKit reports and re-pins, so the repair does not depend on SwiftUI
/// scheduling another shell update. The window tint itself is now the same
/// label color (`AccentColor` in the asset catalog), so even a bar that does
/// inherit has no coral to inherit.
private struct IthacaTVTabBarTintPin: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> IthacaTVTabBarTintController {
        IthacaTVTabBarTintController()
    }

    func updateUIViewController(_ uiViewController: IthacaTVTabBarTintController, context: Context) {
        uiViewController.pinTabBarTint()
    }
}

private final class IthacaTVTabBarTintController: UIViewController {
    private var hasPendingPin = false

    private lazy var sentinel: IthacaTVTabBarTintSentinel = {
        let sentinel = IthacaTVTabBarTintSentinel(frame: .zero)
        sentinel.isUserInteractionEnabled = false
        sentinel.backgroundColor = .clear
        sentinel.onTintColorChange = { [weak self] in
            self?.scheduleTabBarTintRepair()
        }
        return sentinel
    }()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pinTabBarTint()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pinTabBarTint()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        pinTabBarTint()
    }

    func pinTabBarTint() {
        applyTabBarTint()

        // A navigation pop or player dismissal can re-tint the bar later in the
        // same update pass, so take a second look once the run loop settles.
        scheduleTabBarTintRepair()
    }

    /// Re-applies the tint on the next run loop turn. Used both after a shell
    /// update and when the sentinel reports that the bar's tint changed, which
    /// keeps the repair out of UIKit's own tint-change notification pass.
    private func scheduleTabBarTintRepair() {
        guard !hasPendingPin else { return }
        hasPendingPin = true
        DispatchQueue.main.async { [weak self] in
            self?.hasPendingPin = false
            self?.applyTabBarTint()
        }
    }

    private func applyTabBarTint() {
        guard let tabBar = resolvedTabBar() else { return }
        installSentinel(in: tabBar)
        guard tabBar.tintColor != UIColor.ithacaTVTabBarTint else { return }
        tabBar.tintColor = .ithacaTVTabBarTint
    }

    private func installSentinel(in tabBar: UITabBar) {
        guard sentinel.superview !== tabBar else { return }
        sentinel.removeFromSuperview()
        tabBar.addSubview(sentinel)
    }

    private func resolvedTabBar() -> UITabBar? {
        if let tabBar = tabBarController?.tabBar {
            return tabBar
        }
        // The shell is always hosted in a tab bar controller today; the view
        // search only covers a host that keeps the bar outside the parent chain.
        guard let window = view.window else { return nil }
        return Self.firstTabBar(in: window)
    }

    private static func firstTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar {
            return tabBar
        }

        for subview in view.subviews {
            if let tabBar = firstTabBar(in: subview) {
                return tabBar
            }
        }

        return nil
    }
}

/// Invisible subview of the tab bar. UIKit calls `tintColorDidChange()` on
/// every subview whenever the bar's effective tint changes, explicit or
/// inherited, which is the one hook that fires no matter who re-tinted the bar.
private final class IthacaTVTabBarTintSentinel: UIView {
    var onTintColorChange: (() -> Void)?

    override func tintColorDidChange() {
        super.tintColorDidChange()
        onTintColorChange?()
    }
}
