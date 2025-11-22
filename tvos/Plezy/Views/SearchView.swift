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
    @State private var selectedMedia: PlexMetadata?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 30) {
                // Spacer for top navigation
                Color.clear.frame(height: 100)

                // Header
                Text("Search")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color.beaconTextSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.horizontal, 80)

                // Search field with Liquid Glass
                TextField("Search for movies, shows, and more...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .padding(20)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium)
                                .fill(.regularMaterial)
                                .opacity(0.5)

                            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.beaconBlue.opacity(0.1),
                                            Color.beaconPurple.opacity(0.08)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .blendMode(.plusLighter)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium)
                            .strokeBorder(
                                Color.beaconPurple.opacity(0.3),
                                lineWidth: DesignTokens.borderWidthUnfocused
                            )
                    )
                    .foregroundColor(.white)
                    .padding(.horizontal, 80)
                    .onChange(of: searchQuery) { _, newValue in
                        Task {
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

                        SearchGridLayoutView(
                            items: searchResults,
                            onItemTapped: { item in
                                selectedMedia = item
                            }
                        )
                        .padding(.top, 20)
                        .padding(.bottom, 80)
                    }
                }
            }
        }
        .sheet(item: $selectedMedia) { media in
            MediaDetailView(media: media)
        }
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty, let client = authService.currentClient else {
            searchResults = []
            return
        }

        // Debounce search
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        // Check if query has changed
        guard query == searchQuery else { return }

        isSearching = true

        do {
            let results = try await client.search(query: query)
            searchResults = results
        } catch {
            print("Search error: \(error)")
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

/// Grid layout view with 4 columns and consistent spacing for search results
struct SearchGridLayoutView: View {
    let items: [PlexMetadata]
    let onItemTapped: (PlexMetadata) -> Void

    @EnvironmentObject var authService: PlexAuthService
    @State private var availableWidth: CGFloat = 1920

    // Layout constants - larger cards for immersive experience
    private let columnsCount = 4  // Fewer columns = larger cards
    private let spacing: CGFloat = 48
    private let aspectRatio: CGFloat = 236.0 / 420.0 // Height / Width (16:9)

    private var cardWidth: CGFloat {
        // Calculate card width: availableWidth - edge padding - internal spacing
        let totalHorizontalSpacing = (2 * spacing) + (CGFloat(columnsCount - 1) * spacing)
        let availableForCards = availableWidth - totalHorizontalSpacing
        return availableForCards / CGFloat(columnsCount)
    }

    private var cardHeight: CGFloat {
        cardWidth * aspectRatio
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnsCount)
    }

    var body: some View {
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
        .padding(.horizontal, spacing)
        .onPreferenceChange(SearchGridWidthPreferenceKey.self) { width in
            availableWidth = width
        }
    }
}

#Preview {
    SearchView()
        .environmentObject(PlexAuthService())
}
