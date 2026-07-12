import AppKit
import SwiftUI

/// Full-screen, paginated app grid. `TabView`'s `.page` style is iOS-only,
/// so paging is built from a horizontal `ScrollView` with native
/// `.scrollTargetBehavior(.paging)` snapping (macOS 14+), which also gets
/// trackpad two-finger swipe for free. A custom dot row mirrors the classic
/// Launchpad page indicator, and a top search field live-filters the grid.
struct GridView: View {
    @ObservedObject var store: AppStore
    let onDismiss: () -> Void

    @State private var currentPage: Int?
    @State private var launchingID: String?
    @State private var hoveredID: String?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    // `pages` used to be a computed property, re-filtering and re-chunking
    // the entire app list on *every* SwiftUI body evaluation — which fires
    // on every hover event and every scroll-position tick while paging.
    // Redoing that work dozens of times a second while swiping was the
    // actual cause of the slow/glitchy transitions: recomputed here once,
    // only when the underlying data (`store.apps`, `searchText`) actually
    // changes, instead of on every render.
    @State private var pages: [[AppInfo]] = []

    private let columns = 7
    private let rows = 5

    // SwiftUI's plain `withAnimation { }` uses the implicit default spring
    // (~0.55s, fairly loose), which reads as noticeably sluggish next to
    // classic Launchpad's snappy page-flip — and next to the native
    // trackpad-swipe paging above, which uses its own quick system physics.
    // Using the same explicit, quick curve everywhere a page change is
    // triggered programmatically (mouse-drag release, page-dot tap) keeps
    // every path feeling consistent and fast.
    fileprivate static let pageChangeAnimation: Animation = .easeOut(duration: 0.28)

    var body: some View {
        ZStack {
            // Anything not covered by an icon dismisses the overlay on tap.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 20) {
                SearchField(text: $searchText, isFocused: $searchFocused)
                    .padding(.top, 28)

                GeometryReader { geo in
                    // Classic Launchpad's centered, "framed" look (content at
                    // ~68% of screen width, matched off a reference
                    // screenshot) used to be done with horizontal padding
                    // applied *inside* each page. That put each page's own
                    // margin inside its own scroll-content slot, so
                    // mid-transition — with two adjacent pages each partially
                    // visible — both pages' margins landed in the middle of
                    // the screen at once: a ~32%-wide blank gap between the
                    // outgoing and incoming icons (confirmed frame-by-frame
                    // in a user-provided recording). Constraining the
                    // ScrollView itself to that 68% width instead, and
                    // sizing pages to fill it exactly with zero padding,
                    // moves the margin outside the scrollable area entirely
                    // — it's just static background on either side that
                    // never moves, and adjacent pages slide directly flush
                    // against each other with no gap.
                    let contentWidth = geo.size.width * 0.68

                    VStack(spacing: 20) {
                        ScrollView(.horizontal) {
                            // Plain `HStack`, not `LazyHStack`: a Mac's page
                            // count is small (even a heavily-loaded machine
                            // rarely exceeds 8-10 pages of 35 apps each), and
                            // laziness was costing more than it saved —
                            // pages just outside the lazy-load window could
                            // still be settling their layout while a fast
                            // swipe reached them, which is what produced the
                            // brief "two pages' icons visible at once"
                            // glitch. Laying out every page up front avoids
                            // that entirely, at negligible memory cost.
                            HStack(spacing: 0) {
                                ForEach(Array(pages.enumerated()), id: \.offset) { index, pageApps in
                                    pageGrid(pageApps, containerWidth: contentWidth, containerHeight: geo.size.height)
                                        .containerRelativeFrame(.horizontal)
                                        .id(index)
                                }
                            }
                            .scrollTargetLayout()
                            .background(ScrollbarHider())
                        }
                        .frame(width: contentWidth)
                        .scrollTargetBehavior(QuickPagingBehavior())
                        .scrollPosition(id: $currentPage)
                        .scrollIndicators(.hidden)
                        .scrollDisabled(pages.count <= 1)
                        // Trackpad two-finger swipe already works above for
                        // free via the ScrollView's native paging. Plain
                        // mouse click-drag needs separate handling since
                        // AppKit doesn't route that to scroll views at all —
                        // but a SwiftUI `DragGesture` composed alongside the
                        // ScrollView (via `.simultaneousGesture`) turned out
                        // to *also* intermittently respond to trackpad pans,
                        // racing the ScrollView's own native snap decision
                        // and producing exactly the "pages overlapping"
                        // glitch reported during testing — two independent
                        // systems both animating to a (sometimes different)
                        // final page. A raw local event monitor watching
                        // only genuine `leftMouseDown`/`leftMouseUp` sees
                        // nothing when a trackpad is swiped (that arrives as
                        // `.scrollWheel` events instead), so it can't
                        // conflict by construction.
                        .background(
                            MouseDragPager { translation in
                                let threshold: CGFloat = 80
                                let page = currentPage ?? 0
                                if translation < -threshold {
                                    withAnimation(Self.pageChangeAnimation) { currentPage = min(page + 1, pages.count - 1) }
                                } else if translation > threshold {
                                    withAnimation(Self.pageChangeAnimation) { currentPage = max(page - 1, 0) }
                                }
                            }
                        )

                        if pages.count > 1 {
                            PageIndicator(count: pages.count, currentPage: $currentPage)
                        }
                    }
                    // Constraining the ScrollView to `contentWidth` makes it
                    // (and this whole VStack, which sizes to its widest
                    // child) narrower than the GeometryReader itself — and
                    // GeometryReader places a narrower child at its
                    // top-leading corner, not centered, which left all the
                    // now-unused width as blank space on the right instead
                    // of splitting it evenly on both sides. Explicitly
                    // filling and centering within the GeometryReader's full
                    // width restores the centered, framed look.
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { recomputePages() }
        .onChange(of: store.apps) { recomputePages() }
        .onChange(of: searchText) {
            currentPage = 0
            recomputePages()
        }
        .onExitCommand {
            if !searchText.isEmpty {
                searchText = ""
            } else {
                onDismiss()
            }
        }
    }

    private func recomputePages() {
        let filtered = searchText.isEmpty
            ? store.apps
            : store.apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        let perPage = max(columns * rows, 1)
        let newPages = stride(from: 0, to: filtered.count, by: perPage).map {
            Array(filtered[$0..<min($0 + perPage, filtered.count)])
        }
        // The live app-list monitor can update `store.apps` several times in
        // quick succession while it's still settling (initial gather, then
        // follow-up updates) — each one reshuffles which app lands on which
        // page. Without this, SwiftUI implicitly cross-fades the `ForEach`
        // between the old and new page contents, which for a brief moment
        // visibly overlapped two different apps' labels at the same grid
        // position. Disabling animation for this specific assignment makes
        // it a clean, instant swap instead.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pages = newPages
        }
    }

    /// Icons scale with the available cell width instead of a fixed size,
    /// so they fill their grid cell the way classic Launchpad's do rather
    /// than looking small and lost on wide/high-column-count screens.
    ///
    /// `containerWidth` here is already the narrowed, framed content width
    /// (the caller constrains the ScrollView itself to ~68% of the screen)
    /// — this just fills it edge to edge, with no additional margin of its
    /// own, so adjacent pages sit flush against each other with no gap
    /// during a swipe.
    @ViewBuilder
    private func pageGrid(_ pageApps: [AppInfo], containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
        let horizontalSpacing: CGFloat = 32
        let cellWidth = (containerWidth - horizontalSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        // 0.45 undershot next to the reference once rendered — bumped to
        // 0.55, with the cap raised to match so it doesn't get clipped back
        // down on typical screen widths.
        let iconSize = min(max(cellWidth * 0.55, 64), 140)

        // Row spacing was a fixed 32pt regardless of available height, so 5
        // rows never filled the space — everything stayed top-aligned with
        // a big dead gap before the page dots instead of extending closer
        // to them like real Launchpad's. Deriving it from `containerHeight`
        // the same way column width is derived from `containerWidth` makes
        // the 5 rows actually fill the vertical space.
        let topInset: CGFloat = 40
        let bottomReserve: CGFloat = 48 // room for the page-dot row below
        let labelHeight: CGFloat = 16
        let iconLabelGap: CGFloat = 8
        let rowContentHeight = iconSize + iconLabelGap + labelHeight
        let availableForRows = max(containerHeight - topInset - bottomReserve, rowContentHeight * CGFloat(rows))
        let rowPitch = availableForRows / CGFloat(rows)
        let verticalSpacing = max(rowPitch - rowContentHeight, horizontalSpacing)

        // The tap-to-dismiss catcher lives here (on the grid content) and
        // not on the ScrollView above: stacking a plain `.onTapGesture`
        // directly alongside the ScrollView's `.simultaneousGesture(
        // DragGesture)` reliably broke rendering (confirmed by bisection —
        // the whole overlay stopped compositing at all, even though every
        // Swift-level call still returned normally). Putting it on a
        // separate, more deeply nested view avoids the conflict entirely,
        // and still covers the gaps between icons — the vast majority of
        // the "empty" area a user would actually click.
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: horizontalSpacing), count: columns),
            spacing: verticalSpacing
        ) {
            ForEach(pageApps) { app in
                AppIconView(
                    app: app,
                    iconSize: iconSize,
                    labelWidth: cellWidth,
                    isHovered: hoveredID == app.id,
                    isLaunching: launchingID == app.id
                )
                .onHover { hoveredID = $0 ? app.id : nil }
                .onTapGesture { launch(app) }
            }
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    private func launch(_ app: AppInfo) {
        guard launchingID == nil else { return }
        launchingID = app.id

        NSWorkspace.shared.openApplication(
            at: app.bundleURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onDismiss)
    }
}

private struct SearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))

            TextField("", text: $text, prompt: Text("Search").foregroundStyle(.white.opacity(0.55)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .font(.system(size: 13))
                .focused(isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: 240)
        .background(Capsule().fill(.white.opacity(0.14)))
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .onAppear { isFocused.wrappedValue = true }
    }
}

/// Apple's stock `.paging` scroll target behavior seems to require a fairly
/// large drag distance (or a very fast velocity) to commit to changing
/// pages — fine for a continuous trackpad drag, but a Magic Mouse's swipe
/// gesture is a short, quick flick rather than a sustained drag, and often
/// doesn't clear that bar. The result: the swipe registers, but the page
/// snaps right back to where it started instead of advancing, reading as
/// "slow to respond" — the first swipe seems to do nothing, and it takes a
/// second, more deliberate one to actually move. This behavior commits to
/// the next/previous page on either a smaller drag distance (roughly a
/// sixth of the page width) *or* a fast-enough flick regardless of distance
/// travelled, so a short, fast swipe (Magic Mouse) and a longer, slower
/// drag (trackpad) both reliably change pages on the first try.
private struct QuickPagingBehavior: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let pageWidth = context.containerSize.width
        guard pageWidth > 0, context.contentSize.width > pageWidth else { return }

        let originalOffset = context.originalTarget.rect.minX
        let proposedOffset = target.rect.minX
        let velocity = context.velocity.dx

        let currentPage = (originalOffset / pageWidth).rounded()
        var destinationPage = currentPage

        let distanceThreshold = pageWidth / 6
        let velocityThreshold: CGFloat = 200

        if proposedOffset - originalOffset > distanceThreshold || velocity > velocityThreshold {
            destinationPage = currentPage + 1
        } else if originalOffset - proposedOffset > distanceThreshold || velocity < -velocityThreshold {
            destinationPage = currentPage - 1
        }

        let maxOffset = context.contentSize.width - pageWidth
        target.rect.origin.x = min(max(destinationPage * pageWidth, 0), maxOffset)
    }
}

/// Detects genuine mouse click-drag-release sequences via a raw local event
/// monitor rather than SwiftUI's `DragGesture`. Trackpad two-finger swipes
/// arrive as `.scrollWheel` events, never `.leftMouseDown`/`.leftMouseUp`, so
/// this can't ever fire for one — unlike `DragGesture` composed alongside a
/// `ScrollView`, which was found to sometimes respond to trackpad pans too,
/// racing the ScrollView's own native paging. The monitor only observes
/// events (always returning them unmodified), so it never blocks normal
/// clicks on icons, the search field, or page dots.
private struct MouseDragPager: NSViewRepresentable {
    let onSwipe: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private let onSwipe: (CGFloat) -> Void
        private var monitor: Any?
        private var startPoint: NSPoint?

        init(onSwipe: @escaping (CGFloat) -> Void) {
            self.onSwipe = onSwipe
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                switch event.type {
                case .leftMouseDown:
                    self.startPoint = event.locationInWindow
                case .leftMouseUp:
                    if let start = self.startPoint {
                        self.onSwipe(event.locationInWindow.x - start.x)
                    }
                    self.startPoint = nil
                default:
                    break
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

/// `.scrollIndicators(.hidden)` only suppresses the modern overlay
/// scroller; when the system-wide "Show scroll bars: Always" preference is
/// on, AppKit falls back to a legacy `NSScroller` that ignores it. This
/// reaches into the `ScrollView`'s backing `NSScrollView` and turns the
/// scroller off directly so no track/thumb is ever drawn.
private struct ScrollbarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { hideScrollers(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        hideScrollers(from: nsView)
    }

    private func hideScrollers(from view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
    }
}

private struct PageIndicator: View {
    let count: Int
    @Binding var currentPage: Int?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == (currentPage ?? 0) ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .onTapGesture {
                        withAnimation(GridView.pageChangeAnimation) { currentPage = index }
                    }
            }
        }
        .padding(.bottom, 24)
    }
}

private struct AppIconView: View {
    let app: AppInfo
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let isHovered: Bool
    let isLaunching: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .scaleEffect(isLaunching ? 0.85 : (isHovered ? 1.08 : 1.0))
                .opacity(isLaunching ? 0.4 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovered)
                .animation(.easeOut(duration: 0.18), value: isLaunching)

            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .contentShape(Rectangle())
    }
}
