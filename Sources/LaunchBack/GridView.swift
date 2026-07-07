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

    private let columns = 7

    private var rows: Int {
        (NSScreen.main?.frame.height ?? 900) < 900 ? 4 : 5
    }

    private var filteredApps: [AppInfo] {
        guard !searchText.isEmpty else { return store.apps }
        return store.apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var pages: [[AppInfo]] {
        let perPage = max(columns * rows, 1)
        return stride(from: 0, to: filteredApps.count, by: perPage).map {
            Array(filteredApps[$0..<min($0 + perPage, filteredApps.count)])
        }
    }

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
                    VStack(spacing: 20) {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 0) {
                                ForEach(Array(pages.enumerated()), id: \.offset) { index, pageApps in
                                    pageGrid(pageApps, containerWidth: geo.size.width)
                                        .containerRelativeFrame(.horizontal)
                                        .id(index)
                                }
                            }
                            .scrollTargetLayout()
                            .background(ScrollbarHider())
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollPosition(id: $currentPage)
                        .scrollIndicators(.hidden)
                        .scrollDisabled(pages.count <= 1)
                        // The 80pt "framed" inset from the screen edge only
                        // belongs at the very start/end of the whole strip,
                        // not on every page — contentMargins applies it
                        // there. (See pageGrid's own comment for why it
                        // can't live on each page instead.)
                        .contentMargins(.horizontal, 64, for: .scrollContent)
                        // Trackpad two-finger swipe already works above for
                        // free — that's a scroll-wheel event, which
                        // `ScrollView` handles natively. A plain mouse drag
                        // is a different event type AppKit doesn't route to
                        // scroll views at all, so without this, swiping with
                        // a mouse silently does nothing. `simultaneousGesture`
                        // (not `gesture`) so it only *adds* page-flip-on-
                        // release behavior instead of stealing the scroll
                        // view's own trackpad handling.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded { value in
                                    let threshold: CGFloat = 80
                                    let page = currentPage ?? 0
                                    if value.translation.width < -threshold {
                                        withAnimation { currentPage = min(page + 1, pages.count - 1) }
                                    } else if value.translation.width > threshold {
                                        withAnimation { currentPage = max(page - 1, 0) }
                                    }
                                }
                        )

                        if pages.count > 1 {
                            PageIndicator(count: pages.count, currentPage: $currentPage)
                        }
                    }
                }
            }
        }
        .onChange(of: searchText) { currentPage = 0 }
        .onExitCommand {
            if !searchText.isEmpty {
                searchText = ""
            } else {
                onDismiss()
            }
        }
    }

    /// Icons scale with the available cell width instead of a fixed size,
    /// so they fill their grid cell the way classic Launchpad's do rather
    /// than looking small and lost on wide/high-column-count screens.
    @ViewBuilder
    private func pageGrid(_ pageApps: [AppInfo], containerWidth: CGFloat) -> some View {
        // Each page is its own view sitting directly next to the next one
        // in the `LazyHStack` — any horizontal padding here gets applied on
        // *both* sides of *every* page, so at a page boundary it stacks
        // (this page's trailing padding + the next page's leading padding),
        // producing an oversized dead gap mid-swipe instead of a smooth
        // continuous strip. Using half of the column spacing here means
        // adjacent pages' padding sums to exactly one column gap (32pt) —
        // indistinguishable from the spacing between any two columns in the
        // same page. The larger 80pt inset from the true screen edge comes
        // from `.contentMargins` on the ScrollView instead, which (unlike
        // per-page padding) only applies once, at the very start and end of
        // the whole scrollable strip.
        let horizontalPadding: CGFloat = 16
        let spacing: CGFloat = 32
        let availableWidth = containerWidth - horizontalPadding * 2 - spacing * CGFloat(columns - 1)
        let cellWidth = availableWidth / CGFloat(columns)
        let iconSize = min(max(cellWidth * 0.64, 64), 132)

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
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
            spacing: 32
        ) {
            ForEach(pageApps) { app in
                AppIconView(
                    app: app,
                    iconSize: iconSize,
                    isHovered: hoveredID == app.id,
                    isLaunching: launchingID == app.id
                )
                .onHover { hoveredID = $0 ? app.id : nil }
                .onTapGesture { launch(app) }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 40)
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
                        withAnimation { currentPage = index }
                    }
            }
        }
        .padding(.bottom, 24)
    }
}

private struct AppIconView: View {
    let app: AppInfo
    let iconSize: CGFloat
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
                .frame(width: iconSize + 24)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .contentShape(Rectangle())
    }
}
