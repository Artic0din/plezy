//
//  HomeView.swift
//  Beacon tvOS
//
//  Home screen with full-screen hero background and overlaid content
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var authService: PlexAuthService
    @EnvironmentObject var tabCoordinator: TabCoordinator
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var onDeck: [PlexMetadata] = []
    @State private var recentlyAdded: [PlexMetadata] = []
    @State private var hubs: [PlexHub] = []
    @State private var isLoading = true
    // Navigation path for hierarchical navigation (detail views)
    @State private var navigationPath = NavigationPath()
    @State private var playingMedia: PlexMetadata?
    @State private var showServerSelection = false
    @State private var noServerSelected = false
    @State private var errorMessage: String?
    @State private var currentHeroIndex = 0
    @State private var heroProgress: Double = 0.0
    @State private var heroTimer: Timer?
    @State private var scrollOffset: CGFloat = 0
    @State private var shouldShowHero = true
    @State private var isReturningFromDetail = false

    private let heroDisplayDuration: TimeInterval = 7.0
    private let heroTimerInterval: TimeInterval = 0.1  // 100ms for efficiency (was 50ms)

    private let cache = CacheService.shared

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()

                if isLoading {
                    HomeViewSkeleton()
                } else if let error = errorMessage {
                    errorView(error: error)
                } else if noServerSelected {
                    noServerView
                } else {
                    fullScreenHeroLayout
                }

                // Offline banner overlay
                VStack {
                    OfflineBanner()
                    Spacer()
                }
            }
            .navigationDestination(for: PlexMetadata.self) { media in
                MediaDetailView(media: media)
                    .environmentObject(authService)
                    .onAppear {
                        print("📱 [HomeView] MediaDetailView appeared for: \(media.title)")
                    }
                    .onDisappear {
                        // Defer refresh to allow focus to settle after navigation pop
                        print("📱 [HomeView] MediaDetailView disappeared, deferring refresh")
                        Task {
                            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 second delay
                            await refreshOnDeck()
                        }
                    }
            }
        }
        .onAppear {
            print("🏠 [HomeView] View appeared, isReturningFromDetail: \(isReturningFromDetail)")
            startHeroTimer()
            // Only refresh if not returning from detail view (prevents focus loss flash)
            if !isReturningFromDetail {
                Task {
                    await refreshOnDeck()
                }
            }
            isReturningFromDetail = false
        }
        .onDisappear {
            stopHeroTimer()
        }
        .task {
            print("🏠 [HomeView] .task modifier triggered")
            await loadContent()
        }
        // Video player remains fullScreenCover (modal playback with AVPlayerViewController)
        .fullScreenCover(item: $playingMedia) { media in
            let _ = print("🎬 [HomeView] FullScreenCover presenting VideoPlayerView for: \(media.title)")
            VideoPlayerView(media: media)
                .environmentObject(authService)
                .onAppear {
                    print("🎬 [HomeView] VideoPlayerView appeared for: \(media.title)")
                }
                .onDisappear {
                    // Mark that we're returning to prevent immediate refresh that causes focus flash
                    isReturningFromDetail = true
                    print("🎬 [HomeView] VideoPlayerView disappeared, deferring refresh")
                }
        }
        .sheet(isPresented: $showServerSelection) {
            ServerSelectionView()
        }
        .onChange(of: authService.selectedServer) { _, newServer in
            if newServer != nil {
                Task {
                    await loadContent()
                }
            }
        }
        .onReceive(authService.$currentClient) { client in
            // Load content when client becomes available (fixes initial load timing)
            // Check if we have no content yet and client is now available
            if client != nil && (noServerSelected || (onDeck.isEmpty && hubs.isEmpty && !isLoading)) {
                print("🏠 [HomeView] Client became available, loading content...")
                noServerSelected = false
                Task {
                    await loadContent()
                }
            }
        }
        .onChange(of: playingMedia) { oldValue, newValue in
            // Refresh Continue Watching when returning from video playback (with delay for focus)
            if oldValue != nil && newValue == nil {
                print("🏠 [HomeView] Video player dismissed, deferring Continue Watching refresh...")
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay for focus
                    await refreshOnDeck()
                }
            }
        }
    }

    // MARK: - Full-Screen Hero Layout

    private var fullScreenHeroLayout: some View {
        ZStack {
            // Layer 1: Full-screen hero background (recently added)
            if !recentlyAdded.isEmpty {
                FullScreenHeroBackground(
                    items: recentlyAdded,
                    currentIndex: $currentHeroIndex
                )
                .opacity(shouldShowHero ? 1 : 0)
            }

            // Layer 2: Scrollable content area with hero info block
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Spacer with hero info overlay - CW position locked regardless of synopsis length
                        ZStack(alignment: .bottomLeading) {
                            // Scroll tracking layer
                            GeometryReader { geometry in
                                Color.clear
                                    .preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("scroll")).minY)
                            }

                            // Hero Info Block - overlaid at bottom, grows upward
                            if !recentlyAdded.isEmpty {
                                VStack(alignment: .leading, spacing: 24) {
                                    FullScreenHeroOverlay(
                                        item: recentlyAdded[currentHeroIndex]
                                    )
                                }
                                .opacity(shouldShowHero ? 1 : 0)
                                .padding(.bottom, 20) // Gap from bottom of spacer to CW
                            }
                        }
                        .frame(height: 720) // Fixed height - Continue Watching position locked

                        // Continue Watching section - exactly 4 cards visible
                        if !onDeck.isEmpty {
                            ContinueWatchingRow(
                                items: onDeck,
                                onPlay: { item in
                                    playingMedia = item
                                },
                                onContextAction: { action, item in
                                    handleContextAction(action, for: item)
                                }
                            )
                        }

                        // Other hub rows - exactly 4 cards visible per row
                        // Only filter out Continue Watching and On Deck (shown separately)
                        // Keep "Recently Added Movies/TV" etc as they are valuable content rows
                        let filteredHubs = hubs.filter {
                            let title = $0.title.lowercased()
                            return !title.contains("on deck") &&
                                   !title.contains("continue watching")
                        }

                        #if DEBUG
                        let _ = {
                            print("🏠 [HomeView] Total hubs: \(hubs.count), Filtered hubs: \(filteredHubs.count)")
                            for hub in filteredHubs {
                                print("🏠 [HomeView]   Hub: '\(hub.title)' - metadata: \(hub.metadata?.count ?? 0) items")
                            }
                        }()
                        #endif

                        ForEach(filteredHubs) { hub in
                            HubRow(hub: hub) { item in
                                navigationPath.append(item)
                            }
                        }

                    // Bottom padding - add extra space to allow scrolling past Continue Watching
                    Color.clear.frame(height: 600)
                    }
                    .coordinateSpace(name: "scroll")
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                        scrollOffset = value
                        // Hide hero when scrolled past Continue Watching section into rows below
                        // Threshold set to fade out when user scrolls into the hub rows below Continue Watching
                        withAnimation(.easeInOut(duration: 0.4)) {
                            shouldShowHero = value > -850
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Error & No Server Views

    private func errorView(error: String) -> some View {
        VStack(spacing: 30) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 80))
                .foregroundColor(.red)

            Text("Error Loading Content")
                .font(.title)
                .foregroundColor(.white)

            Text(error)
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 100)

            HStack(spacing: 20) {
                Button {
                    print("🔄 [HomeView] Retry button tapped")
                    Task {
                        await loadContent()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.title3)
                }
                .buttonStyle(ClearGlassButtonStyle())
            }
        }
    }

    private var noServerView: some View {
        VStack(spacing: 30) {
            Image(systemName: "server.rack")
                .font(.system(size: 80))
                .foregroundColor(.gray)

            Text("No Server Selected")
                .font(.title)
                .foregroundColor(.white)

            Text("Please select a Plex server to start watching")
                .font(.title3)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button {
                showServerSelection = true
            } label: {
                HStack {
                    Image(systemName: "server.rack")
                    Text("Select Server")
                }
                .font(.title2)
            }
            .buttonStyle(ClearGlassButtonStyle())
        }
    }

    // MARK: - Hero Timer Management

    private func startHeroTimer() {
        heroTimer = Timer.scheduledTimer(withTimeInterval: heroTimerInterval, repeats: true) { _ in
            if !recentlyAdded.isEmpty {
                heroProgress += heroTimerInterval / heroDisplayDuration

                if heroProgress >= 1.0 {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        currentHeroIndex = (currentHeroIndex + 1) % recentlyAdded.count
                    }
                    heroProgress = 0.0
                }
            }
        }
    }

    private func stopHeroTimer() {
        heroTimer?.invalidate()
        heroTimer = nil
    }

    private func resetHeroProgress() {
        heroProgress = 0.0
    }

    private func navigateHero(to index: Int) {
        guard index >= 0 && index < recentlyAdded.count else { return }
        withAnimation(.easeInOut(duration: 0.6)) {
            currentHeroIndex = index
        }
        resetHeroProgress()
    }

    // MARK: - Content Loading

    private func loadContent() async {
        print("🏠 [HomeView] loadContent called")
        print("🏠 [HomeView] currentClient exists: \(authService.currentClient != nil)")

        guard let client = authService.currentClient,
              let serverID = authService.selectedServer?.clientIdentifier else {
            print("🏠 [HomeView] No client available, showing no server selected")
            isLoading = false
            noServerSelected = true
            return
        }

        let cacheKey = CacheService.homeKey(serverID: serverID)

        // Check cache for hubs only (not on-deck, which we always fetch fresh)
        if let cached: (onDeck: [PlexMetadata], hubs: [PlexHub]) = cache.get(cacheKey) {
            print("🏠 [HomeView] Using cached hubs, fetching fresh on-deck...")
            self.hubs = cached.hubs

            // Extract recently added from hubs
            if let recentlyAddedHub = cached.hubs.first(where: { $0.title.lowercased().contains("recently added") || $0.title.lowercased().contains("recent") }),
               let items = recentlyAddedHub.metadata {
                self.recentlyAdded = items
                // Prefetch hero images for smoother transitions
                prefetchHeroImages()
            }

            isLoading = false
            noServerSelected = false

            // Always fetch fresh on-deck data
            do {
                // Clear metadata cache to ensure fresh data
                client.clearMetadataCache()

                let fetchedOnDeck = try await client.getOnDeck()
                self.onDeck = fetchedOnDeck
                // Update cache with fresh on-deck
                cache.set(cacheKey, value: (onDeck: fetchedOnDeck, hubs: cached.hubs))
                print("🏠 [HomeView] Fresh on-deck loaded: \(fetchedOnDeck.count) items")
            } catch {
                print("🔴 [HomeView] Error fetching fresh on-deck: \(error)")
                // Fall back to cached on-deck
                self.onDeck = cached.onDeck
            }
            return
        }

        print("🏠 [HomeView] Client available, loading fresh content...")
        isLoading = true
        noServerSelected = false
        errorMessage = nil

        // Clear metadata cache to ensure fresh data
        client.clearMetadataCache()

        async let onDeckTask = client.getOnDeck()
        async let hubsTask = client.getHubs()

        do {
            print("🏠 [HomeView] Fetching on deck and hubs...")
            let fetchedOnDeck = try await onDeckTask
            let fetchedHubs = try await hubsTask

            self.onDeck = fetchedOnDeck
            self.hubs = fetchedHubs

            // Extract recently added from hubs
            if let recentlyAddedHub = fetchedHubs.first(where: { $0.title.lowercased().contains("recently added") || $0.title.lowercased().contains("recent") }),
               let items = recentlyAddedHub.metadata {
                self.recentlyAdded = items
                print("🏠 [HomeView] Recently Added items: \(items.count)")
                // Prefetch hero images for smoother transitions
                prefetchHeroImages()
            }

            // Cache the results
            cache.set(cacheKey, value: (onDeck: fetchedOnDeck, hubs: fetchedHubs))

            print("🏠 [HomeView] Content loaded successfully. OnDeck: \(self.onDeck.count), Hubs: \(self.hubs.count), RecentlyAdded: \(self.recentlyAdded.count)")
            errorMessage = nil
        } catch {
            print("🔴 [HomeView] Error loading content: \(error)")
            print("🔴 [HomeView] Error details: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
        print("🏠 [HomeView] loadContent complete")
    }

    private func refreshContent() async {
        guard let serverID = authService.selectedServer?.clientIdentifier else {
            return
        }

        print("🔄 [HomeView] Refreshing content...")

        // Invalidate cache
        let cacheKey = CacheService.homeKey(serverID: serverID)
        cache.invalidate(cacheKey)

        // Reload content
        await loadContent()
    }

    /// Prefetch hero images for smoother transitions
    private func prefetchHeroImages() {
        guard !recentlyAdded.isEmpty else { return }

        // Prefetch next 3 hero images (or all if fewer)
        let count = min(recentlyAdded.count, 3)
        var urls: [URL] = []

        for i in 0..<count {
            if let url = artURL(for: recentlyAdded[i]) {
                urls.append(url)
            }
        }

        if !urls.isEmpty {
            #if DEBUG
            print("🖼️ [HomeView] Prefetching \(urls.count) hero images")
            #endif
            ImageCacheService.shared.prefetch(urls: urls)
        }
    }

    /// Build art URL for hero image prefetching
    private func artURL(for media: PlexMetadata) -> URL? {
        guard let server = authService.selectedServer,
              let baseURL = server.bestBaseURL,
              let art = media.art else {
            return nil
        }

        var urlString = baseURL.absoluteString + art
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
    }

    /// Lightweight refresh of just the Continue Watching row after video playback
    private func refreshOnDeck() async {
        guard let client = authService.currentClient,
              let serverID = authService.selectedServer?.clientIdentifier else {
            return
        }

        do {
            // Clear metadata cache to ensure fresh data from Plex
            // This is important when content is watched in other Plex clients
            client.clearMetadataCache()

            let fetchedOnDeck = try await client.getOnDeck()
            self.onDeck = fetchedOnDeck

            // Update cache with new onDeck data
            let cacheKey = CacheService.homeKey(serverID: serverID)
            cache.set(cacheKey, value: (onDeck: fetchedOnDeck, hubs: self.hubs))

            print("🔄 [HomeView] Continue Watching refreshed: \(fetchedOnDeck.count) items")
        } catch {
            print("🔴 [HomeView] Error refreshing Continue Watching: \(error)")
        }
    }

    // MARK: - Context Menu Actions

    /// Handle context menu actions for Continue Watching items
    private func handleContextAction(_ action: MediaCardContextAction, for item: PlexMetadata) {
        guard let client = authService.currentClient,
              let ratingKey = item.ratingKey else {
            print("⚠️ [HomeView] Cannot perform action - missing client or ratingKey")
            return
        }

        Task {
            do {
                switch action {
                case .markWatched:
                    try await client.markAsWatched(ratingKey: ratingKey)
                    // Remove from local list immediately for responsive UI
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.3)) {
                            onDeck.removeAll { $0.ratingKey == ratingKey }
                        }
                    }
                    print("✅ [HomeView] Marked \(item.title) as watched")

                case .markUnwatched:
                    try await client.markAsUnwatched(ratingKey: ratingKey)
                    // Refresh to get updated state
                    await refreshOnDeck()
                    print("✅ [HomeView] Marked \(item.title) as unwatched")

                case .removeFromContinueWatching:
                    try await client.removeFromContinueWatching(ratingKey: ratingKey)
                    // Remove from local list immediately for responsive UI
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.3)) {
                            onDeck.removeAll { $0.ratingKey == ratingKey }
                        }
                    }
                    print("✅ [HomeView] Removed \(item.title) from Continue Watching")
                }
            } catch {
                print("🔴 [HomeView] Context action failed: \(error)")
                // Refresh to sync state
                await refreshOnDeck()
            }
        }
    }
}

// MARK: - Full-Screen Hero Background

struct FullScreenHeroBackground: View {
    let items: [PlexMetadata]
    @Binding var currentIndex: Int
    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Sliding background images
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        CachedAsyncImage(url: artURL(for: item)) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                }
                .offset(x: -CGFloat(currentIndex) * geometry.size.width)
                .animation(.easeInOut(duration: 0.6), value: currentIndex)

                // Gradient at bottom to help Continue Watching row stand out
                VStack {
                    Spacer()
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.clear,
                            Color.black.opacity(0.6),
                            Color.black.opacity(0.9)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: geometry.size.height / 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private func artURL(for media: PlexMetadata) -> URL? {
        guard let server = authService.selectedServer,
              let baseURL = server.bestBaseURL,
              let art = media.art else {
            return nil
        }

        var urlString = baseURL.absoluteString + art
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
    }
}

// MARK: - Full-Screen Hero Overlay

struct FullScreenHeroOverlay: View {
    let item: PlexMetadata
    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Show logo or title in fixed-height container
            VStack(alignment: .leading) {
                if let clearLogo = item.clearLogo, let logoURL = logoURL(for: clearLogo) {
                    CachedAsyncImage(url: logoURL) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        Text(item.type == "episode" ? (item.grandparentTitle ?? item.title) : item.title)
                            .font(.system(size: 76, weight: .bold, design: .default))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 4)
                    }
                    .frame(maxWidth: 600, maxHeight: 180, alignment: .leading)
                    .id("\(item.id)-\(clearLogo)") // Force refresh when item changes
                } else {
                    Text(item.type == "episode" ? (item.grandparentTitle ?? item.title) : item.title)
                        .font(.system(size: 76, weight: .bold, design: .default))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 4)
                        .frame(maxWidth: 900, alignment: .leading)
                }
            }
            .frame(height: 180, alignment: .leading) // Fixed height for logo

            // Metadata line with Liquid Glass styling
            HStack(spacing: 10) {
                Text(item.type == "movie" ? "Movie" : "TV Show")
                    .font(.system(size: 24, weight: .medium, design: .default))
                    .foregroundColor(.white)

                if item.audienceRating != nil || item.contentRating != nil || item.year != nil {
                    ForEach(metadataComponents(for: item), id: \.self) { component in
                        Text("·")
                            .foregroundColor(.white.opacity(0.7))
                        Text(component)
                            .font(.system(size: 24, weight: .medium, design: .default))
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .opacity(0.5)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )

            // Synopsis - grows upward when long, bottom stays anchored near Continue Watching
            if let summary = item.summary {
                if item.type == "episode", let parentIndex = item.parentIndex, let index = item.index {
                    Text("S\(parentIndex), E\(index): \(summary)")
                        .font(.system(size: 28, weight: .regular, design: .default))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(nil) // Allow unlimited wrapping
                        .frame(maxWidth: 1000, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)
                } else {
                    Text(summary)
                        .font(.system(size: 28, weight: .regular, design: .default))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(nil) // Allow unlimited wrapping
                        .frame(maxWidth: 1000, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)
                }
            }

        }
        .padding(.horizontal, CardRowLayout.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func logoURL(for clearLogo: String) -> URL? {
        if clearLogo.starts(with: "http") {
            return URL(string: clearLogo)
        }

        guard let server = authService.selectedServer,
              let baseURL = server.bestBaseURL else {
            return nil
        }

        var urlString = baseURL.absoluteString + clearLogo
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
    }

    private func metadataComponents(for item: PlexMetadata) -> [String] {
        var components: [String] = []

        if let rating = item.audienceRating {
            components.append("★ \(String(format: "%.1f", rating))")
        }

        if let contentRating = item.contentRating {
            components.append(contentRating)
        }

        if let year = item.year {
            components.append(String(year))
        }

        return components
    }
}

// MARK: - Top Navigation Menu

struct TopNavigationMenu: View {
    @EnvironmentObject var tabCoordinator: TabCoordinator

    var body: some View {
        HStack(spacing: 40) {
            ForEach(TabSelection.allCases, id: \.self) { tab in
                TopMenuItem(
                    tab: tab,
                    isSelected: tabCoordinator.selectedTab == tab,
                    action: {
                        tabCoordinator.select(tab)
                    }
                )
            }

            Spacer()
        }
        .padding(.horizontal, CardRowLayout.horizontalPadding)
        .padding(.vertical, 20)
    }
}

struct TopMenuItem: View {
    let tab: TabSelection
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(tab.rawValue)
                    .font(.system(size: 28, weight: isSelected ? .bold : .semibold, design: .default))
                    .foregroundColor(.white)

                if isSelected {
                    Capsule()
                        .fill(Color.beaconGradient)
                        .frame(height: 4)
                        .shadow(color: Color.beaconPurple.opacity(0.8), radius: 8, x: 0, y: 0)
                } else {
                    Capsule()
                        .fill(Color.clear)
                        .frame(height: 4)
                }
            }
        }
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .shadow(
            color: isFocused ? Color.white.opacity(0.5) : Color.clear,
            radius: isFocused ? 20 : 0,
            x: 0,
            y: 0
        )
    }
}

// MARK: - Scroll Offset Preference Key

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    HomeView()
        .environmentObject(PlexAuthService())
        .environmentObject(SettingsService())
}
