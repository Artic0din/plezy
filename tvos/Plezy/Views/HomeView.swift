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
    @State private var selectedMedia: PlexMetadata?
    @State private var playingMedia: PlexMetadata?
    @State private var showServerSelection = false
    @State private var noServerSelected = false
    @State private var errorMessage: String?
    @State private var currentHeroIndex = 0
    @State private var heroProgress: Double = 0.0
    @State private var heroTimer: Timer?
    @State private var scrollOffset: CGFloat = 0
    @State private var shouldShowHero = true

    private let heroDisplayDuration: TimeInterval = 7.0
    private let heroTimerInterval: TimeInterval = 0.05

    private let cache = CacheService.shared

    var body: some View {
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
        .onAppear {
            print("🏠 [HomeView] View appeared")
            startHeroTimer()
            // Refresh Continue Watching on every appear to ensure up-to-date data
            Task {
                await refreshOnDeck()
            }
        }
        .onDisappear {
            stopHeroTimer()
        }
        .task {
            print("🏠 [HomeView] .task modifier triggered")
            await loadContent()
        }
        .fullScreenCover(item: $selectedMedia) { media in
            let _ = print("📱 [HomeView] FullScreenCover presenting MediaDetailView for: \(media.title)")
            MediaDetailView(media: media)
                .environmentObject(authService)
                .onAppear {
                    print("📱 [HomeView] MediaDetailView appeared for: \(media.title)")
                }
        }
        .fullScreenCover(item: $playingMedia) { media in
            let _ = print("🎬 [HomeView] FullScreenCover presenting VideoPlayerView for: \(media.title)")
            VideoPlayerView(media: media)
                .environmentObject(authService)
                .onAppear {
                    print("🎬 [HomeView] VideoPlayerView appeared for: \(media.title)")
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
            // Refresh Continue Watching when returning from video playback
            if oldValue != nil && newValue == nil {
                print("🏠 [HomeView] Video player dismissed, refreshing Continue Watching...")
                Task {
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
                            ContinueWatchingRow(items: onDeck) { item in
                                playingMedia = item
                            }
                        }

                        // Other hub rows - exactly 4 cards visible per row
                        ForEach(hubs.filter {
                            let title = $0.title.lowercased()
                            return !title.contains("recently added") &&
                                   !title.contains("on deck") &&
                                   !title.contains("continue watching")
                        }) { hub in
                            HubRow(hub: hub) { item in
                                selectedMedia = item
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
            .buttonStyle(.borderedProminent)
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

        // Check cache first
        if let cached: (onDeck: [PlexMetadata], hubs: [PlexHub]) = cache.get(cacheKey) {
            print("🏠 [HomeView] Using cached content")
            self.onDeck = cached.onDeck
            self.hubs = cached.hubs

            // Extract recently added from hubs
            if let recentlyAddedHub = cached.hubs.first(where: { $0.title.lowercased().contains("recently added") || $0.title.lowercased().contains("recent") }),
               let items = recentlyAddedHub.metadata {
                self.recentlyAdded = items
            }

            isLoading = false
            noServerSelected = false
            return
        }

        print("🏠 [HomeView] Client available, loading fresh content...")
        isLoading = true
        noServerSelected = false
        errorMessage = nil

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

    /// Lightweight refresh of just the Continue Watching row after video playback
    private func refreshOnDeck() async {
        guard let client = authService.currentClient,
              let serverID = authService.selectedServer?.clientIdentifier else {
            return
        }

        do {
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
              let connection = server.connections.first,
              let baseURL = connection.url,
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

            // Metadata line
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
              let connection = server.connections.first,
              let baseURL = connection.url else {
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
        .buttonStyle(PlainButtonStyle())
        .focusable()
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
