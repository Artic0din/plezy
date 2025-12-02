//
//  SearchView.swift
//  Beacon tvOS
//
//  Global search across all libraries
//

import SwiftUI

struct SearchView: View {
    @EnvironmentObject var authService: PlexAuthService
    @EnvironmentObject var tabCoordinator: TabCoordinator
    @State private var searchQuery = ""
    @State private var searchResults: [PlexMetadata] = []
    @State private var isSearching = false
    // Navigation path for hierarchical navigation
    @State private var navigationPath = NavigationPath()
    @State private var searchTask: Task<Void, Never>?

    private let cache = CacheService.shared

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 30) {
                // Spacer for top navigation
                Color.clear.frame(height: 100)

                // Header
                Text("Search")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 80)

                // Search field with Liquid Glass
                TextField("Search for movies, shows, and more...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium)
                            .fill(Color.white.opacity(0.15))
                    )
                    .foregroundColor(.white)
                    .padding(.horizontal, 80)
                    .onChange(of: searchQuery) { _, newValue in
                        // Cancel previous search task
                        searchTask?.cancel()
                        searchTask = Task {
                            await performSearch(query: newValue)
                        }
                    }

                // Results
                if isSearching {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Searching...")
                            .foregroundColor(.gray)
                            .padding(.top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchQuery.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)

                        Text("Start typing to search")
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)

                        Text("No results found")
                            .font(.title2)
                            .foregroundColor(.gray)

                        Text("Try a different search term")
                            .font(.headline)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        GeometryReader { geometry in
                            Color.clear.preference(key: SearchGridWidthPreferenceKey.self, value: geometry.size.width)
                        }
                        .frame(height: 0)

                        SearchResultsView(
                            results: searchResults,
                            onItemTapped: { item in
                                navigationPath.append(item)
                            }
                        )
                        .padding(.top, 20)
                        .padding(.bottom, 80)
                    }
                }
                }
            }
            .navigationDestination(for: PlexMetadata.self) { media in
                MediaDetailView(media: media)
                    .environmentObject(authService)
            }
        }
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty, let client = authService.currentClient,
              let serverID = authService.selectedServer?.clientIdentifier else {
            searchResults = []
            return
        }

        // Debounce search
        do {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        } catch {
            // Task was cancelled
            return
        }

        // Check if task was cancelled or query changed
        guard !Task.isCancelled, query == searchQuery else { return }

        // Check cache first
        let cacheKey = "search_\(serverID)_\(query.lowercased())"
        if let cached: [PlexMetadata] = cache.get(cacheKey) {
            searchResults = cached
            return
        }

        isSearching = true

        do {
            let results = try await client.search(query: query)
            // Only update if task wasn't cancelled
            guard !Task.isCancelled else { return }
            searchResults = results
            // Cache results for 1 hour
            cache.set(cacheKey, value: results, ttl: 3600)
        } catch {
            guard !Task.isCancelled else { return }
            #if DEBUG
            print("Search error: \(error)")
            #endif
            searchResults = []
        }

        isSearching = false
    }
}

// MARK: - Search Grid Layout

/// Preference key for tracking available grid width
struct SearchGridWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 1920
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Categorized search results with section headings
/// Uses CardRowLayout constants for consistency with home screen rows
struct SearchResultsView: View {
    let results: [PlexMetadata]
    let onItemTapped: (PlexMetadata) -> Void

    @EnvironmentObject var authService: PlexAuthService

    // Use CardRowLayout constants for consistency across the app
    private var cardWidth: CGFloat { CardRowLayout.cardWidth }
    private var cardHeight: CGFloat { CardRowLayout.cardHeight }
    private var spacing: CGFloat { CardRowLayout.cardSpacing }
    private let columnsCount = Int(CardRowLayout.visibleCardCount)

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnsCount)
    }

    // Separate results by type
    private var movies: [PlexMetadata] {
        results.filter { $0.type == "movie" }
    }

    private var tvShows: [PlexMetadata] {
        results.filter { $0.type == "show" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            // Movies Section
            if !movies.isEmpty {
                SearchSection(
                    title: "Movies",
                    icon: "film.fill",
                    items: movies,
                    columns: columns,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    spacing: spacing,
                    onItemTapped: onItemTapped
                )
                .environmentObject(authService)
            }

            // TV Shows Section
            if !tvShows.isEmpty {
                SearchSection(
                    title: "TV Shows",
                    icon: "tv.fill",
                    items: tvShows,
                    columns: columns,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    spacing: spacing,
                    onItemTapped: onItemTapped
                )
                .environmentObject(authService)
            }
        }
    }
}

/// Section with header and grid of items
/// Uses CardRowLayout constants for consistency
struct SearchSection: View {
    let title: String
    let icon: String
    let items: [PlexMetadata]
    let columns: [GridItem]
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let spacing: CGFloat
    let onItemTapped: (PlexMetadata) -> Void

    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section Header
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("(\(items.count))")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, CardRowLayout.horizontalPadding)

            // Grid
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(items) { item in
                    MediaCard(
                        media: item,
                        config: .custom(
                            width: cardWidth,
                            height: cardHeight,
                            showProgress: true,
                            showLabel: .inside,
                            showLogo: true,
                            showEpisodeLabelBelow: false
                        )
                    ) {
                        onItemTapped(item)
                    }
                }
            }
            .padding(.horizontal, CardRowLayout.horizontalPadding)
        }
    }
}

#Preview {
    SearchView()
        .environmentObject(PlexAuthService())
}
