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
    @State private var episodes: [PlexMetadata] = []
    @State private var selectedSeason: PlexMetadata?
    @State private var onDeckEpisode: PlexMetadata?
    @State private var isLoading = true
    @State private var selectedEpisode: PlexMetadata?
    @State private var showVideoPlayer = false
    @State private var playMedia: PlexMetadata?
    @State private var trailers: [PlexMetadata] = []
    @State private var focusedEpisode: PlexMetadata?
    @State private var isEpisodeRowFocused = false

    var body: some View {
        let _ = print("📄 [MediaDetailView] body evaluated for: \(media.title)")
        ZStack {
            // Layer 1: Background
            backgroundLayer

            // Layer 2: Base Content (Hero info + Bottom sheet)
            baseContentLayer

            // Layer 3: MediaCard Overlay (when episode row is focused)
            if isEpisodeRowFocused, let episode = focusedEpisode {
                overlayMediaCard(for: episode)
            }
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
            print("👁️ [MediaDetailView] authService: \(authService)")
            print("👁️ [MediaDetailView] Has client: \(authService.currentClient != nil)")
        }
    }

    // MARK: - Layer Views

    /// Layer 1: Background with blurred/dimmed artwork
    private var backgroundLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let artURL = artworkURL {
                CachedAsyncImage(url: artURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 20)
                } placeholder: {
                    Color.black
                }
                .opacity(0.3)
                .ignoresSafeArea()
            }
        }
    }

    /// Layer 2: Base content with hero info and bottom sheet
    private var baseContentLayer: some View {
        VStack(spacing: 0) {
            // Hero info section (left side, upper part)
            HStack {
                VStack(alignment: .leading, spacing: 20) {
                    // Clear logo or title
                    if let clearLogo = displayMedia.clearLogo, let logoURL = logoURL(for: clearLogo) {
                        CachedAsyncImage(url: logoURL) { image in
                            image
                                .resizable()
                                .scaledToFit()
                        } placeholder: {
                            Text(displayMedia.title)
                                .font(.system(size: 60, weight: .heavy, design: .default))
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: 600, maxHeight: 180, alignment: .leading)
                    } else {
                        Text(displayMedia.title)
                            .font(.system(size: 60, weight: .heavy, design: .default))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }

                    // Metadata chips
                    HStack(spacing: 12) {
                        Text(displayMedia.type == "movie" ? "Movie" : "TV Show")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white)

                        if displayMedia.audienceRating != nil || displayMedia.contentRating != nil || displayMedia.year != nil || displayMedia.duration != nil {
                            ForEach(metadataComponents, id: \.self) { component in
                                Text("·")
                                    .foregroundColor(.white.opacity(0.7))
                                Text(component)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                    }

                    // Summary
                    if let summary = summaryText, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 26, weight: .regular))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(4)
                            .frame(maxWidth: 1200, alignment: .leading)
                    }

                    // Action buttons
                    HStack(spacing: 20) {
                        // Play button (primary)
                        Button {
                            handlePlayButton()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                Text(playButtonLabel)
                                    .font(.system(size: 24, weight: .semibold))
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
                                    .font(.system(size: 24))
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
                                        .font(.system(size: 20))
                                    Text("Trailer")
                                        .font(.system(size: 22, weight: .medium))
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
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.leading, 60)
                .padding(.top, 60)

                Spacer()
            }

            Spacer()

            // Bottom sheet with season selector and episode row
            if displayMedia.type == "show" && !seasons.isEmpty {
                bottomSheet
            }
        }
    }

    /// Bottom sheet containing season selector and episode row
    private var bottomSheet: some View {
        VStack(alignment: .leading, spacing: 30) {
            // Season selector
            if seasons.count > 1 {
                seasonSelector
            }

            // Episode row
            if !episodes.isEmpty {
                episodeRow
            }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.8)
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: -10)
        )
    }

    /// Season selector horizontal scroll
    private var seasonSelector: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Season")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(seasons) { season in
                        Button {
                            selectedSeason = season
                            Task {
                                await loadEpisodesForSeason(season)
                            }
                        } label: {
                            Text(season.title)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(selectedSeason?.id == season.id ? .white : .white.opacity(0.6))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(
                                    ZStack {
                                        Capsule()
                                            .fill(Color.clear)

                                        if selectedSeason?.id == season.id {
                                            Capsule()
                                                .fill(Color.beaconGradient)
                                        }
                                    }
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .tvOSScrollClipDisabled()
        }
    }

    /// Episode row horizontal scroll
    private var episodeRow: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Episodes")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 30) {
                        ForEach(episodes) { episode in
                            EpisodeCard(episode: episode) {
                                playMedia = episode
                            } onFocusChange: { focused in
                                if focused {
                                    focusedEpisode = episode
                                    isEpisodeRowFocused = true
                                } else if focusedEpisode?.id == episode.id {
                                    // If this was the focused episode and it lost focus, clear the overlay
                                    isEpisodeRowFocused = false
                                    focusedEpisode = nil
                                }
                            }
                            .id(episode.id)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .tvOSScrollClipDisabled()
                .onAppear {
                    // Scroll to first unwatched episode
                    if let firstUnwatched = episodes.first(where: { !$0.isWatched }) {
                        withAnimation {
                            scrollProxy.scrollTo(firstUnwatched.id, anchor: .leading)
                        }
                    }
                }
                .onChange(of: episodes) { _, newEpisodes in
                    // Scroll to first unwatched episode when episodes change (season change)
                    if let firstUnwatched = newEpisodes.first(where: { !$0.isWatched }) {
                        withAnimation {
                            scrollProxy.scrollTo(firstUnwatched.id, anchor: .leading)
                        }
                    }
                }
            }
        }
    }

    /// Layer 3: MediaCard overlay (shown when episode is focused)
    private func overlayMediaCard(for episode: PlexMetadata) -> some View {
        ZStack {
            // Dimming background
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            // Large centered card
            VStack(alignment: .leading, spacing: 20) {
                // Episode thumbnail with gradient
                ZStack(alignment: .bottomLeading) {
                    if let thumbURL = episodeThumbnailURL(for: episode) {
                        CachedAsyncImage(url: thumbURL) { image in
                            image
                                .resizable()
                                .aspectRatio(16/9, contentMode: .fill)
                        } placeholder: {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .aspectRatio(16/9, contentMode: .fill)
                        }
                    }

                    // Gradient overlay for text readability
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.8)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                // Episode info
                VStack(alignment: .leading, spacing: 12) {
                    // Episode number
                    if let season = episode.parentIndex, let episodeNum = episode.index {
                        Text("S\(season), E\(episodeNum)")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.gray)
                    }

                    // Episode title
                    Text(episode.title)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    // Episode summary
                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(4)
                    }

                    // Duration and progress
                    HStack(spacing: 12) {
                        if let duration = episode.duration {
                            Text(formatDuration(duration))
                                .font(.system(size: 20))
                                .foregroundColor(.gray)
                        }

                        if episode.progress > 0 && episode.progress < 0.98 {
                            Text("•")
                                .foregroundColor(.gray)
                            Text("\(Int(episode.progress * 100))% watched")
                                .font(.system(size: 20))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
            .frame(width: 1000)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: Color.beaconPurple.opacity(0.4), radius: 40, x: 0, y: 20)
            )
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isEpisodeRowFocused)
    }

    private var displayMedia: PlexMetadata {
        detailedMedia ?? media
    }

    private var summaryText: String? {
        // For TV shows with on-deck episodes, show episode synopsis
        if displayMedia.type == "show", let episode = onDeckEpisode {
            // Use episode summary if available, otherwise fall back to show summary
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
        // clearLogo already includes the full URL from the Image array
        if clearLogo.starts(with: "http") {
            return URL(string: clearLogo)
        }

        // Fallback to building URL if it's a relative path
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

    private func handlePlayButton() {
        if displayMedia.type == "show" {
            if let episode = onDeckEpisode {
                playMedia = episode
            } else if let firstSeason = seasons.first {
                selectedSeason = firstSeason
            }
        } else {
            playMedia = displayMedia
        }
    }

    private func handleShufflePlay() {
        // For future implementation: shuffle play
        print("🔀 [MediaDetailView] Shuffle play requested for: \(displayMedia.title)")
    }

    private func handleTrailerPlay() {
        if let trailer = trailers.first {
            playMedia = trailer
        }
    }

    private func loadDetails() async {
        guard let client = authService.currentClient,
              let ratingKey = media.ratingKey else {
            return
        }

        isLoading = true

        do {
            // Fetch metadata and handle show/movie specific logic concurrently
            let detailed = try await client.getMetadata(ratingKey: ratingKey)
            detailedMedia = detailed

            // If it's a TV show, load seasons, onDeck, and episodes concurrently
            if media.type == "show" {
                async let seasonsTask = client.getChildren(ratingKey: ratingKey)
                async let onDeckTask = client.getOnDeck()

                // Wait for both to complete
                let (loadedSeasons, onDeckItems) = try await (seasonsTask, onDeckTask)
                seasons = loadedSeasons

                // Find onDeck episode for this show
                onDeckEpisode = onDeckItems.first { episode in
                    episode.grandparentRatingKey == ratingKey
                }

                // Load episodes for the first season
                if let firstSeason = seasons.first {
                    selectedSeason = firstSeason
                    if let seasonRatingKey = firstSeason.ratingKey {
                        episodes = try await client.getChildren(ratingKey: seasonRatingKey)
                        print("📺 [MediaDetailView] Loaded \(episodes.count) episodes for \(firstSeason.title)")

                        // Prefetch episode thumbnails for faster display
                        let thumbnailURLs = episodes.compactMap { episodeThumbnailURL(for: $0) }
                        ImageCacheService.shared.prefetch(urls: thumbnailURLs)
                    }
                }

                print("📺 [MediaDetailView] OnDeck episode for show: \(onDeckEpisode?.title ?? "none")")
            }

            // If it's a movie, load trailers
            if media.type == "movie" {
                do {
                    let extras = try await client.getExtras(ratingKey: ratingKey)
                    // Filter for trailers only (Plex uses "1" for trailer extra type)
                    trailers = extras.filter { extra in
                        extra.type == "clip" && (extra.title.lowercased().contains("trailer") || extra.summary?.lowercased().contains("trailer") == true)
                    }
                    print("🎬 [MediaDetailView] Found \(trailers.count) trailer(s) for movie")
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

            // Reload details
            await loadDetails()
        } catch {
            print("Error toggling watched: \(error)")
        }
    }

    private func loadEpisodesForSeason(_ season: PlexMetadata) async {
        guard let client = authService.currentClient,
              let ratingKey = season.ratingKey else {
            return
        }

        do {
            episodes = try await client.getChildren(ratingKey: ratingKey)
            print("📺 [MediaDetailView] Loaded \(episodes.count) episodes for \(season.title)")

            // Prefetch episode thumbnails for faster display
            let thumbnailURLs = episodes.compactMap { episodeThumbnailURL(for: $0) }
            ImageCacheService.shared.prefetch(urls: thumbnailURLs)
        } catch {
            print("Error loading episodes for season: \(error)")
            episodes = []
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

// MARK: - Episode Card

/// Episode card for horizontal scrolling in bottom sheet
struct EpisodeCard: View {
    let episode: PlexMetadata
    let action: () -> Void
    let onFocusChange: (Bool) -> Void
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
                    .frame(width: 450, height: 253)

                    // Progress bar
                    if episode.progress > 0 && episode.progress < 0.98 {
                        VStack {
                            Spacer()
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(.regularMaterial)
                                        .opacity(0.4)

                                    Capsule()
                                        .fill(Color.beaconGradient)
                                        .frame(width: geometry.size.width * episode.progress)
                                        .shadow(color: Color.beaconMagenta.opacity(0.5), radius: 4, x: 0, y: 0)
                                }
                            }
                            .frame(height: 6)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                    }

                    // Play icon on focus
                    if isFocused {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                            .shadow(radius: 10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusLarge, style: .continuous))

                // Episode info
                VStack(alignment: .leading, spacing: 6) {
                    if let episodeNum = episode.index {
                        Text("Episode \(episodeNum)")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.gray)
                    }

                    Text(episode.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .frame(width: 450, alignment: .leading)
                }
                .padding(.top, 12)
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: isFocused ? Color.beaconPurple.opacity(0.5) : .clear, radius: isFocused ? 20 : 0, x: 0, y: isFocused ? 10 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange(focused)
        }
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

// MARK: - Season Grid Layout

/// Preference key for tracking available grid width
struct SeasonGridWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 1920
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Grid layout view with 5 columns and consistent spacing for seasons
struct SeasonGridView: View {
    let seasons: [PlexMetadata]
    let onSeasonTapped: (PlexMetadata) -> Void

    @EnvironmentObject var authService: PlexAuthService
    @State private var availableWidth: CGFloat = 1920

    // Layout constants
    private let columnsCount = 5
    private let spacing: CGFloat = 48
    private let aspectRatio: CGFloat = 3.0 / 2.0 // 2:3 poster ratio (height/width)

    private var cardWidth: CGFloat {
        // Calculate card width: availableWidth - edge padding - internal spacing
        let totalHorizontalSpacing = (CGFloat(columnsCount - 1) * spacing)
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
            ForEach(seasons) { season in
                SeasonCard(
                    season: season,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    action: {
                        onSeasonTapped(season)
                    }
                )
            }
        }
        .onPreferenceChange(SeasonGridWidthPreferenceKey.self) { width in
            availableWidth = width
        }
    }
}

struct SeasonCard: View {
    let season: PlexMetadata
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                CachedAsyncImage(url: posterURL) { image in
                    image
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay(
                            Image(systemName: "tv")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        )
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusXLarge, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusXLarge, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: isFocused ? [
                                    Color.beaconBlue.opacity(0.9),
                                    Color.beaconPurple.opacity(0.7)
                                ] : [.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isFocused ? DesignTokens.borderWidthFocusedThick : 0
                        )
                )
                .shadow(color: isFocused ? Color.beaconPurple.opacity(0.5) : .black.opacity(0.5), radius: isFocused ? 35 : 18, x: 0, y: isFocused ? 18 : 10)
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .animation(DesignTokens.Animation.quick.spring(), value: isFocused)

                Text(season.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)

                if let leafCount = season.leafCount {
                    Text("\(leafCount) episode\(leafCount == 1 ? "" : "s")")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                        .frame(width: cardWidth, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }

    private var posterURL: URL? {
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url,
              let thumb = season.thumb else {
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
