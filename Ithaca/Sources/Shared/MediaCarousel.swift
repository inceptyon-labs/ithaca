import SwiftUI

/// Reusable horizontal carousel with a section title.
struct MediaCarousel<Content: View>: View {
    let title: String
    let horizontalPadding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        horizontalPadding: CGFloat = IthacaPosterMetrics.carouselHorizontalPadding,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.horizontalPadding = horizontalPadding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IthacaPosterMetrics.carouselSectionSpacing) {
            Text(title)
                .font(IthacaFont.sectionHeader(ios: .title3.bold()))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: IthacaPosterMetrics.carouselItemSpacing) {
                    content()
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, IthacaPosterMetrics.carouselBottomPadding)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .carouselLeadingFocusLock(leadingInset: horizontalPadding)
        }
    }
}

/// tvOS: what Home asks of the shelf its hero's down-press lands on.
///
/// Home does not let the focus engine's own pick stand (it picked the third
/// card, or a row further down). It scrolls the page to the fold and asks the
/// shelf's first item to take focus. See `HomeTVView.beginHeroExit`.
///
/// None of this disables anything. A row with nothing focusable left in it
/// is stood in for by a focusable filler item, and a move into that filler
/// ends wherever UIKit then decides.
enum CarouselLeadingItemRequest {
    case none
    /// Scroll back to the first item, but only while the row is off screen.
    case rewindWhenHidden
    /// Scroll back to the first item now.
    case rewind
    /// Scroll back to the first item and focus it; again on every bump of
    /// `carouselLeadingFocusGeneration` while the request stands.
    case focus
}

extension EnvironmentValues {
    /// A carousel honours it with `carouselLeadingFocusLock(leadingInset:)` on
    /// its scroll view, `carouselItemFocusLock(isLeadingItem:)` on every item,
    /// and `carouselLeadingFocusTarget()` on the focusable view of an item.
    @Entry var carouselLeadingItemRequest = CarouselLeadingItemRequest.none
    /// Bumped by whoever made a `.focus` request to have the item take focus
    /// again after it lost it. The requester decides, not the item: a request
    /// it has just withdrawn must not be answered by a stale re-assertion.
    @Entry var carouselLeadingFocusGeneration = 0
}

/// Whether any carousel item holds focus.
struct CarouselItemFocusedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Whether the item a `.focus` request asked for now holds focus.
struct CarouselLeadingItemFocusedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Applies `carouselLeadingItemRequest` to a carousel's horizontal scroll
    /// view. `leadingInset` is the content's leading padding.
    ///
    /// The first item sits in a lazy stack, so it only exists while the row is
    /// at its leading edge. Until a row asked to `.focus` has been rewound, its
    /// items only see `.rewind`; the first one is asked for focus once it is in
    /// view.
    func carouselLeadingFocusLock(leadingInset: CGFloat) -> some View {
        modifier(CarouselLeadingFocusLock(leadingInset: leadingInset))
    }

    /// Marks one carousel item for `carouselLeadingItemRequest`: only the
    /// leading item sees the request.
    func carouselItemFocusLock(isLeadingItem: Bool) -> some View {
        modifier(CarouselItemFocusLock(isLeadingItem: isLeadingItem))
    }

    /// Put this on the focusable view of a carousel item (the button, not its
    /// container). It takes focus when a `.focus` request reaches it.
    func carouselLeadingFocusTarget() -> some View {
        modifier(OwnedCarouselLeadingFocusTarget())
    }

    /// For an item that already binds its own `@FocusState` with
    /// `.focused(_:)`: the request is answered through that binding, so the
    /// item carries one focus state instead of two.
    func carouselLeadingFocusTarget(_ isFocused: FocusState<Bool>.Binding) -> some View {
        modifier(CarouselLeadingFocusTarget(isFocused: isFocused, hasFocus: isFocused.wrappedValue))
    }
}

private struct CarouselLeadingFocusLock: ViewModifier {
    let leadingInset: CGFloat

    #if os(tvOS)
    @Environment(\.carouselLeadingItemRequest) private var request
    @State private var scrollPosition = ScrollPosition()
    @State private var isLeadingItemInView = true
    @State private var isOnScreen = true
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // The first item's leading edge is inside the viewport.
                geometry.contentOffset.x + geometry.contentInsets.leading <= leadingInset
            } action: { _, isInView in
                isLeadingItemInView = isInView
            }
            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                isOnScreen = isVisible
                rewindIfRequested()
            }
            .onChange(of: request) { _, _ in
                rewindIfRequested()
            }
            .environment(
                \.carouselLeadingItemRequest,
                request == .focus ? (isLeadingItemInView ? .focus : .rewind) : .none
            )
        #else
        content
        #endif
    }

    #if os(tvOS)
    private func rewindIfRequested() {
        switch request {
        case .none:
            return
        case .rewindWhenHidden:
            // Nobody can see it, so the row never visibly jumps.
            guard !isOnScreen else { return }
        case .rewind, .focus:
            break
        }

        guard !isLeadingItemInView else { return }
        scrollPosition.scrollTo(edge: .leading)
    }
    #endif
}

private struct CarouselItemFocusLock: ViewModifier {
    let isLeadingItem: Bool

    #if os(tvOS)
    @Environment(\.carouselLeadingItemRequest) private var request
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .environment(\.carouselLeadingItemRequest, isLeadingItem ? request : .none)
        #else
        content
        #endif
    }
}

/// `carouselLeadingFocusTarget()` for a single button with no focus state of
/// its own.
private struct OwnedCarouselLeadingFocusTarget: ViewModifier {
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .focused($isFocused)
            .modifier(CarouselLeadingFocusTarget(isFocused: $isFocused, hasFocus: isFocused))
        #else
        content
        #endif
    }
}

private struct CarouselLeadingFocusTarget: ViewModifier {
    let isFocused: FocusState<Bool>.Binding
    /// Read by the owner of the focus state as it builds this modifier. The
    /// owner re-renders on every change of its focus, so a plain value field
    /// that differs is what makes the preferences below follow it.
    let hasFocus: Bool

    #if os(tvOS)
    @Environment(\.carouselLeadingItemRequest) private var request
    @Environment(\.carouselLeadingFocusGeneration) private var generation
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        let wantsFocus = request == .focus

        content
            // A task rather than `onChange`, so an item that only materialises
            // after the request was made still answers it.
            .task(id: wantsFocus ? generation : nil) {
                guard wantsFocus else { return }
                isFocused.wrappedValue = true
                // An item that has only just materialised may not be in the
                // focus system yet. Withdrawing the request cancels this.
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled, !isFocused.wrappedValue {
                    isFocused.wrappedValue = true
                }
            }
            .preference(key: CarouselLeadingItemFocusedKey.self, value: wantsFocus && hasFocus)
            .preference(key: CarouselItemFocusedKey.self, value: hasFocus)
        #else
        content
        #endif
    }
}
