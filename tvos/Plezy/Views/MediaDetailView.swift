//
//  MediaDetailView.swift
//  Beacon tvOS
//
//  Detailed view for movies and TV shows
//

import SwiftUI

struct MediaDetailView: View {
    let media: PlexMetadata
    @EnvironmentObject var authService: PlexAuthService
    @Environment(\.dismiss) var dismiss
    @State private var detailedMedia: PlexMetadata?
    @State private var seasons: [PlexMetadata] = []
    @State private var allEpisodes: [PlexMetadata] = []  // All episodes from all seasons
    @State private var selectedSeason: PlexMetadata?
    @State private var onDeckEpisode: PlexMetadata?
    @State private var isLoading = true
    @State private var playMedia: PlexMetadata?
    @State private var trailers: [PlexMetadata] = []

    var body: some View {
        let _ = print("📄 [MediaDetailView] body evaluated for: \(media.title)")
        ZStack {
            // Background: dimmed artwork (no blur)
            backgroundLayer

            // Single unified ShowDetailCard
            showDetailCard
        }
        .ignoresSafeArea()
        .task {
            print("⚙️ [MediaDetailView] Task started for: \(media.title)")
            await loadDetails()
            print("⚙️ [MediaDetailView] Task completed for: \(media.title)")
        }
        .fullScreenCover(item: $playMedia) { mediaToPlay in
            let _ = print("🎬 [MediaDetailView] Playing: \(mediaToPlay.title)")
            VideoPlayerView(media: mediaToPlay)
                .environmentObject(authService)
        }
        .onAppear {
            print("👁️ [MediaDetailView] View appeared for: \(media.title)")
        }
    }

    // MARK: - Background (No Blur)

    /// Background with dimmed artwork - NO blur
    private var backgroundLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let artURL = artworkURL {
                CachedAsyncImage(url: artURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.black
                }
                .opacity(0.25)  // Dimmed, not blurred
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Single Unified ShowDetailCard

    /// One unified card containing show info, season selector, and episodes row
    private var showDetailCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Show info section
            showInfoSection
                .padding(.horizontal, 60)
                .padding(.top, 60)
                .padding(.bottom, 40)

            // Season selector and episodes (for TV shows)
            if displayMedia.type == "show" && !seasons.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.2))
                    .padding(.horizontal, 60)

                // Season selector
                seasonSelector
                    .padding(.horizontal, 60)
                    .padding(.top, 30)

                // Episodes row (all episodes from all seasons)
                if !allEpisodes.isEmpty {
                    episodesRow
                        .padding(.top, 20)
                        .padding(.bottom, 40)
                }
            }

            Spacer(minLength: 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 30, x: 0, y: 15)
        )
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
    }

    // MARK: - Show Info Section

    private var showInfoSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Clear logo or title
            if let clearLogo = displayMedia.clearLogo, let logoURL = logoURL(for: clearLogo) {
                CachedAsyncImage(url: logoURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    Text(displayMedia.title)
                        .font(.system(size: 52, weight: .heavy, design: .default))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: 500, maxHeight: 150, alignment: .leading)
            } else {
                Text(displayMedia.title)
                    .font(.system(size: 52, weight: .heavy, design: .default))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            // Metadata chips
            HStack(spacing: 12) {
                Text(displayMedia.type == "movie" ? "Movie" : "TV Show")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                if displayMedia.audienceRating != nil || displayMedia.contentRating != nil || displayMedia.year != nil || displayMedia.duration != nil {
                    ForEach(metadataComponents, id: \.self) { component in
                        Text("·")
                            .foregroundColor(.white.opacity(0.5))
                        Text(component)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }

            // Summary
            if let summary = summaryText, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(3)
                    .frame(maxWidth: 1000, alignment: .leading)
            }

            // Action buttons
            HStack(spacing: 20) {
                // Play button (primary)
                Button {
                    handlePlayButton()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text(playButtonLabel)
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(.clearGlass)

                // Shuffle button (shows/seasons only)
                if displayMedia.type == "show" && !seasons.isEmpty {
                    Button {
                        handleShufflePlay()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(CardButtonStyle())
                }

                // Trailer button (movies only)
                if displayMedia.type == "movie" && !trailers.isEmpty {
                    Button {
                        handleTrailerPlay()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 18))
                            Text("Trailer")
                                .font(.system(size: 20, weight: .medium))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(CardButtonStyle())
                }

                // Mark as watched/unwatched
                Button {
                    Task {
                        await toggleWatched()
                    }
                } label: {
                    Image(systemName: displayMedia.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
                .buttonStyle(CardButtonStyle())
            }
        }
    }

    // MARK: - Season Selector

    private var seasonSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Season")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(seasons) { season in
                        SeasonButton(
                            season: season,
                            isSelected: selectedSeason?.id == season.id
                        ) {
                            selectedSeason = season
                            // Scroll to first episode of this season (handled in episodesRow)
                        }
                    }
                }
            }
            .tvOSScrollClipDisabled()
        }
    }

    // MARK: - Episodes Row (All Episodes from All Seasons)

    private var episodesRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episodes")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 60)

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(allEpisodes) { episode in
                            EpisodeCard(episode: episode) {
                                playMedia = episode
                            }
                            .id(episode.id)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 10)
                }
                .tvOSScrollClipDisabled()
                .onAppear {
                    // Scroll to first unwatched episode
                    scrollToFirstUnwatched(proxy: scrollProxy)
                }
                .onChange(of: selectedSeason) { _, newSeason in
                    // When season changes, scroll to first episode of that season
                    if let season = newSeason {
                        scrollToFirstEpisodeOfSeason(season, proxy: scrollProxy)
                    }
                }
            }
        }
    }

    // MARK: - Scroll Helpers

    private func scrollToFirstUnwatched(proxy: ScrollViewProxy) {
        if let firstUnwatched = allEpisodes.first(where: { !$0.isWatched }) {
            withAnimation {
                proxy.scrollTo(firstUnwatched.id, anchor: .leading)
            }
        }
    }

    private func scrollToFirstEpisodeOfSeason(_ season: PlexMetadata, proxy: ScrollViewProxy) {
        // Find first episode of this season
        if let firstEpisode = allEpisodes.first(where: { $0.parentRatingKey == season.ratingKey }) {
            withAnimation {
                proxy.scrollTo(firstEpisode.id, anchor: .leading)
            }
        }
    }

    // MARK: - Computed Properties

    private var displayMedia: PlexMetadata {
        detailedMedia ?? media
    }

    private var summaryText: String? {
        // For TV shows with on-deck episodes, show episode synopsis
        if displayMedia.type == "show", let episode = onDeckEpisode {
            return episode.summary ?? displayMedia.summary
        }
        return displayMedia.summary
    }

    private var playButtonLabel: String {
        if displayMedia.type == "show" {
            if let episode = onDeckEpisode {
                let seasonNum = episode.parentIndex ?? 1
                let episodeNum = episode.index ?? 1
                if episode.progress > 0 {
                    return "Resume S\(seasonNum)E\(episodeNum)"
                } else {
                    return "Play S\(seasonNum)E\(episodeNum)"
                }
            }
            return "Play S1E1"
        }
        return displayMedia.progress > 0 ? "Resume" : "Play"
    }

    private var metadataComponents: [String] {
        var components: [String] = []

        if let rating = displayMedia.audienceRating {
            components.append("★ \(String(format: "%.1f", rating))")
        }

        if let contentRating = displayMedia.contentRating {
            components.append(contentRating)
        }

        if let year = displayMedia.year {
            components.append(String(year))
        }

        if let duration = displayMedia.duration {
            components.append(formatDuration(duration))
        }

        return components
    }

    private var artworkURL: URL? {
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url,
              let art = displayMedia.art else {
            return nil
        }

        var urlString = baseURL.absoluteString + art
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
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

    // MARK: - Actions

    private func handlePlayButton() {
        if displayMedia.type == "show" {
            if let episode = onDeckEpisode {
                playMedia = episode
            } else if let firstEpisode = allEpisodes.first {
                playMedia = firstEpisode
            }
        } else {
            playMedia = displayMedia
        }
    }

    private func handleShufflePlay() {
        print("🔀 [MediaDetailView] Shuffle play requested for: \(displayMedia.title)")
    }

    private func handleTrailerPlay() {
        if let trailer = trailers.first {
            playMedia = trailer
        }
    }

    // MARK: - Data Loading

    private func loadDetails() async {
        guard let client = authService.currentClient,
              let ratingKey = media.ratingKey else {
            return
        }

        isLoading = true

        do {
            // Fetch metadata
            let detailed = try await client.getMetadata(ratingKey: ratingKey)
            detailedMedia = detailed

            // If it's a TV show, load all seasons and all episodes
            if media.type == "show" {
                async let seasonsTask = client.getChildren(ratingKey: ratingKey)
                async let onDeckTask = client.getOnDeck()

                let (loadedSeasons, onDeckItems) = try await (seasonsTask, onDeckTask)
                seasons = loadedSeasons

                // Set first season as selected
                if let firstSeason = seasons.first {
                    selectedSeason = firstSeason
                }

                // Find onDeck episode for this show
                onDeckEpisode = onDeckItems.first { episode in
                    episode.grandparentRatingKey == ratingKey
                }

                // Load ALL episodes from ALL seasons
                await loadAllEpisodes()

                print("📺 [MediaDetailView] Loaded \(allEpisodes.count) total episodes from \(seasons.count) seasons")
            }

            // If it's a movie, load trailers
            if media.type == "movie" {
                do {
                    let extras = try await client.getExtras(ratingKey: ratingKey)
                    trailers = extras.filter { extra in
                        extra.type == "clip" && (extra.title.lowercased().contains("trailer") || extra.summary?.lowercased().contains("trailer") == true)
                    }
                } catch {
                    print("Error loading trailers: \(error)")
                    trailers = []
                }
            }
        } catch {
            print("Error loading details: \(error)")
        }

        isLoading = false
    }

    /// Load all episodes from all seasons into one flat array
    private func loadAllEpisodes() async {
        guard let client = authService.currentClient else { return }

        var episodes: [PlexMetadata] = []

        // Load episodes from each season concurrently
        await withTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (index, season) in seasons.enumerated() {
                group.addTask {
                    guard let seasonRatingKey = season.ratingKey else {
                        return (index, [])
                    }
                    do {
                        let seasonEpisodes = try await client.getChildren(ratingKey: seasonRatingKey)
                        return (index, seasonEpisodes)
                    } catch {
                        print("Error loading episodes for \(season.title): \(error)")
                        return (index, [])
                    }
                }
            }

            // Collect results maintaining order
            var results: [(Int, [PlexMetadata])] = []
            for await result in group {
                results.append(result)
            }

            // Sort by season index and flatten
            results.sort { $0.0 < $1.0 }
            for (_, seasonEpisodes) in results {
                episodes.append(contentsOf: seasonEpisodes)
            }
        }

        allEpisodes = episodes

        // Prefetch episode thumbnails
        let thumbnailURLs = allEpisodes.compactMap { episodeThumbnailURL(for: $0) }
        ImageCacheService.shared.prefetch(urls: thumbnailURLs)
    }

    private func toggleWatched() async {
        guard let client = authService.currentClient,
              let ratingKey = displayMedia.ratingKey else {
            return
        }

        do {
            if displayMedia.isWatched {
                try await client.unscrobble(ratingKey: ratingKey)
            } else {
                try await client.scrobble(ratingKey: ratingKey)
            }
            await loadDetails()
        } catch {
            print("Error toggling watched: \(error)")
        }
    }

    private func episodeThumbnailURL(for episode: PlexMetadata) -> URL? {
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url,
              let thumb = episode.thumb else {
            return nil
        }

        var urlString = baseURL.absoluteString + thumb
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let hours = minutes / 60

        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Season Button

struct SeasonButton: View {
    let season: PlexMetadata
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(season.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.beaconPurple.opacity(0.8) : Color.white.opacity(0.1))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(isFocused ? 0.8 : 0.2), lineWidth: isFocused ? 2 : 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Episode Card (simplified, no overlay)

struct EpisodeCard: View {
    let episode: PlexMetadata
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Episode thumbnail
                ZStack(alignment: .bottomLeading) {
                    CachedAsyncImage(url: thumbnailURL) { image in
                        image
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .aspectRatio(16/9, contentMode: .fill)
                            .overlay(
                                Image(systemName: "tv")
                                    .font(.largeTitle)
                                    .foregroundColor(.gray)
                            )
                    }
                    .frame(width: 380, height: 214)

                    // Progress bar
                    if episode.progress > 0 && episode.progress < 0.98 {
                        VStack {
                            Spacer()
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.3))

                                    Capsule()
                                        .fill(Color.beaconPurple)
                                        .frame(width: geometry.size.width * episode.progress)
                                }
                            }
                            .frame(height: 4)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                    }

                    // Play icon on focus
                    if isFocused {
                        Color.black.opacity(0.3)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.white)
                            .shadow(radius: 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Episode info
                VStack(alignment: .leading, spacing: 4) {
                    if let seasonNum = episode.parentIndex, let episodeNum = episode.index {
                        Text("S\(seasonNum) E\(episodeNum)")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.gray)
                    }

                    Text(episode.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .frame(width: 380, alignment: .leading)
                }
                .padding(.top, 10)
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(color: isFocused ? Color.beaconPurple.opacity(0.5) : .clear, radius: isFocused ? 15 : 0, x: 0, y: isFocused ? 8 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private var thumbnailURL: URL? {
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url,
              let thumb = episode.thumb else {
            return nil
        }

        var urlString = baseURL.absoluteString + thumb
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
    }
}

#Preview {
    MediaDetailView(media: PlexMetadata(
        ratingKey: "1",
        key: "/library/metadata/1",
        guid: nil,
        studio: nil,
        type: "movie",
        title: "Sample Movie",
        titleSort: nil,
        librarySectionTitle: nil,
        librarySectionID: nil,
        librarySectionKey: nil,
        contentRating: "PG-13",
        summary: "A great movie about something interesting.",
        rating: nil,
        audienceRating: 8.5,
        year: 2024,
        tagline: nil,
        thumb: nil,
        art: nil,
        duration: 7200000,
        originallyAvailableAt: nil,
        addedAt: nil,
        updatedAt: nil,
        audienceRatingImage: nil,
        primaryExtraKey: nil,
        ratingImage: nil,
        viewOffset: nil,
        viewCount: nil,
        lastViewedAt: nil,
        grandparentRatingKey: nil,
        grandparentKey: nil,
        grandparentTitle: nil,
        grandparentThumb: nil,
        grandparentArt: nil,
        parentRatingKey: nil,
        parentKey: nil,
        parentTitle: nil,
        parentThumb: nil,
        parentIndex: nil,
        index: nil,
        childCount: nil,
        leafCount: nil,
        viewedLeafCount: nil,
        media: nil,
        role: nil,
        genre: nil,
        director: nil,
        writer: nil,
        country: nil,
        Image: nil
    ))
    .environmentObject(PlexAuthService())
}
