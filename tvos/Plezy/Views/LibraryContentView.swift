//
//  LibraryContentView.swift
//  Beacon tvOS
//
//  Content browser for a specific library
//

import SwiftUI

struct LibraryContentView: View {
    let library: PlexLibrary
    // Navigation path binding from parent NavigationStack
    @Binding var navigationPath: NavigationPath
    @EnvironmentObject var authService: PlexAuthService
    @Environment(\.dismiss) var dismiss
    @State private var items: [PlexMetadata] = []
    @State private var filteredItems: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var filterStatus: FilterStatus = .all
    @State private var sortOption: SortOption = .recentlyAdded
    @State private var errorMessage: String?
    @State private var currentOffset = 0
    @State private var hasMoreItems = true
    @State private var isLoadingMore = false

    private let cache = CacheService.shared
    private let pageSize = 50

    enum FilterStatus {
        case all
        case unwatched
        case watched
    }

    enum SortOption: String, CaseIterable {
        case recentlyAdded = "Recently Added"
        case titleAsc = "Title (A-Z)"
        case titleDesc = "Title (Z-A)"
        case yearDesc = "Year (Newest)"
        case yearAsc = "Year (Oldest)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Filters
                HStack(spacing: 30) {
                    // Status Filter
                    HStack(spacing: 15) {
                        FilterButton(title: "All", isSelected: filterStatus == .all) {
                            filterStatus = .all
                        }

                        FilterButton(title: "Unwatched", isSelected: filterStatus == .unwatched) {
                            filterStatus = .unwatched
                        }

                        FilterButton(title: "Watched", isSelected: filterStatus == .watched) {
                            filterStatus = .watched
                        }
                    }

                    Spacer()

                    // Sort Menu with Liquid Glass
                    Menu {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Button {
                                sortOption = option
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    if sortOption == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 20))
                            Text(sortOption.rawValue)
                                .font(.system(size: 20, weight: .semibold, design: .default))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 30)

                if isLoading {
                    ScrollView {
                        LibraryGridSkeleton()
                    }
                } else if let error = errorMessage {
                    VStack(spacing: 30) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 80))
                            .foregroundColor(.red)

                        Text("Error Loading Library")
                            .font(.title)
                            .foregroundColor(.white)

                        Text(error)
                            .font(.body)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 100)

                        Button {
                            print("🔄 [LibraryContent] Retry button tapped")
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredItems.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "tray")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)

                        Text(items.isEmpty ? "No content found" : "No items match filters")
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        GeometryReader { geometry in
                            Color.clear.preference(key: GridWidthPreferenceKey.self, value: geometry.size.width)
                        }
                        .frame(height: 0)

                        GridLayoutView(
                            items: filteredItems,
                            hasMoreItems: hasMoreItems,
                            isLoadingMore: isLoadingMore,
                            onItemTapped: { item in
                                print("🎯 [LibraryContent] Item tapped in \(library.title): \(item.title)")
                                navigationPath.append(item)
                            },
                            onLoadMore: {
                                Task {
                                    await loadMoreContent()
                                }
                            }
                        )
                        .padding(.top, 20)
                        .padding(.bottom, 80)
                    }
                }
            }
        }
        .task {
            await loadContent()
        }
        .onChange(of: filterStatus) { oldValue, newValue in
            print("🔄 [LibraryContent] Filter status changed from \(oldValue) to \(newValue)")
            Task {
                // Invalidate cache when filters change
                if let serverID = authService.selectedServer?.clientIdentifier {
                    let cacheKey = CacheService.libraryContentKey(serverID: serverID, libraryKey: library.key)
                    cache.invalidate(cacheKey)
                }
                await loadContent()
            }
        }
        .onChange(of: sortOption) { oldValue, newValue in
            print("🔄 [LibraryContent] Sort option changed from \(oldValue) to \(newValue)")
            Task {
                // Invalidate cache when sort changes
                if let serverID = authService.selectedServer?.clientIdentifier {
                    let cacheKey = CacheService.libraryContentKey(serverID: serverID, libraryKey: library.key)
                    cache.invalidate(cacheKey)
                }
                await loadContent()
            }
        }
        .onChange(of: navigationPath) { oldValue, newValue in
            // Refresh content when returning from media detail (watch status may have changed)
            if oldValue.count > newValue.count {
                print("📚 [LibraryContent] Returned from media detail, refreshing content...")
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 second delay for focus
                    await refreshContent()
                }
            }
        }
    }

    /// Refresh content by invalidating cache and reloading
    private func refreshContent() async {
        guard let serverID = authService.selectedServer?.clientIdentifier else { return }
        let cacheKey = CacheService.libraryContentKey(serverID: serverID, libraryKey: library.key)
        cache.invalidate(cacheKey)
        await loadContent()
    }

    private func loadContent() async {
        guard let _ = authService.currentClient,
              let serverID = authService.selectedServer?.clientIdentifier else {
            return
        }

        let cacheKey = CacheService.libraryContentKey(serverID: serverID, libraryKey: library.key)

        // Check cache first
        if let cached: [PlexMetadata] = cache.get(cacheKey) {
            print("📚 [LibraryContent] Using cached content for \(library.title)")
            self.items = cached
            applyFilters()
            isLoading = false
            return
        }

        print("📚 [LibraryContent] Loading fresh content for \(library.title)...")
        isLoading = true
        errorMessage = nil
        currentOffset = 0
        hasMoreItems = true

        do {
            let fetchedItems = try await fetchItems(start: 0, size: pageSize)
            self.items = fetchedItems

            // Check if there are more items
            hasMoreItems = fetchedItems.count == pageSize
            currentOffset = pageSize

            // Cache the results with 10 minute TTL
            cache.set(cacheKey, value: fetchedItems, ttl: 600)

            applyFilters() // Still apply client-side filters for watched items
            print("📚 [LibraryContent] Content loaded: \(fetchedItems.count) items, hasMore: \(hasMoreItems)")
            errorMessage = nil
        } catch {
            print("Error loading library content: \(error)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadMoreContent() async {
        guard hasMoreItems, !isLoadingMore else { return }
        guard authService.currentClient != nil else { return }

        print("📚 [LibraryContent] Loading more content from offset \(currentOffset)")
        isLoadingMore = true

        do {
            let fetchedItems = try await fetchItems(start: currentOffset, size: pageSize)

            // Append new items
            self.items.append(contentsOf: fetchedItems)

            // Check if there are more items
            hasMoreItems = fetchedItems.count == pageSize
            currentOffset += fetchedItems.count

            applyFilters()
            print("📚 [LibraryContent] Loaded \(fetchedItems.count) more items, total: \(items.count), hasMore: \(hasMoreItems)")
        } catch {
            print("Error loading more content: \(error)")
        }

        isLoadingMore = false
    }

    private func fetchItems(start: Int, size: Int) async throws -> [PlexMetadata] {
        guard let client = authService.currentClient else {
            throw PlexAPIError.unauthorized
        }

        // Map sort option to Plex API sort parameter
        let sortParam: String? = {
            switch sortOption {
            case .recentlyAdded:
                return "addedAt:desc"
            case .titleAsc:
                return "titleSort:asc"
            case .titleDesc:
                return "titleSort:desc"
            case .yearDesc:
                return "year:desc"
            case .yearAsc:
                return "year:asc"
            }
        }()

        // Map filter status to unwatched parameter
        let unwatchedParam: Bool? = {
            switch filterStatus {
            case .unwatched:
                return true
            case .all, .watched:
                return nil // Server-side filtering only supports unwatched
            }
        }()

        return try await client.getLibraryContent(
            sectionKey: library.key,
            start: start,
            size: size,
            sort: sortParam,
            unwatched: unwatchedParam
        )
    }

    private func applyFilters() {
        var filtered = items

        // Apply client-side watch status filter only for "watched" items
        // (unwatched is handled server-side)
        switch filterStatus {
        case .all, .unwatched:
            break // Server handles unwatched filtering
        case .watched:
            filtered = filtered.filter { $0.isWatched }
        }

        // Sorting is now handled server-side via API parameters
        // No need for client-side sorting

        filteredItems = filtered
    }
}

struct FilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .default))
                .foregroundColor(isSelected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.white.opacity(0.3) : Color.white.opacity(isFocused ? 0.2 : 0.1))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isFocused ? Color.white.opacity(0.5) : Color.clear,
                            lineWidth: 2
                        )
                )
        }
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Grid Layout

/// Preference key for tracking available grid width
struct GridWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 1920
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Grid layout view with 4 columns and consistent spacing
/// Uses CardRowLayout constants for consistency with home screen rows
struct GridLayoutView: View {
    let items: [PlexMetadata]
    let hasMoreItems: Bool
    let isLoadingMore: Bool
    let onItemTapped: (PlexMetadata) -> Void
    let onLoadMore: () -> Void

    @EnvironmentObject var authService: PlexAuthService

    // Use CardRowLayout constants for consistency across the app
    private var cardWidth: CGFloat { CardRowLayout.cardWidth }
    private var cardHeight: CGFloat { CardRowLayout.cardHeight }
    private var spacing: CGFloat { CardRowLayout.cardSpacing }
    private let columnsCount = Int(CardRowLayout.visibleCardCount)

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

            // Load more indicator
            if hasMoreItems {
                VStack {
                    if isLoadingMore {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.white)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .onAppear {
                    onLoadMore()
                }
            }
        }
        .padding(.horizontal, CardRowLayout.horizontalPadding)
    }
}

#Preview {
    LibraryContentView(
        library: PlexLibrary(
            key: "1",
            title: "Movies",
            type: "movie",
            agent: nil,
            scanner: nil,
            language: nil,
            uuid: UUID().uuidString,
            updatedAt: nil,
            createdAt: nil,
            scannedAt: nil,
            thumb: nil,
            art: nil
        ),
        navigationPath: .constant(NavigationPath())
    )
    .environmentObject(PlexAuthService())
}
