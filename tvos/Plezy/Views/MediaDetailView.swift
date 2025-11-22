//
//  MediaDetailView.swift
//  Beacon tvOS
//
//  Full-screen hero detail view with:
//  - Full-screen backdrop artwork (unblurred, not globally dimmed)
//  - Bottom-to-middle gradient only for text readability
//  - Reusable MediaDetailContent preserving original layout
//  - Synopsis swaps based on episode focus
//  - Single episodes row with all seasons
//

import SwiftUI

// MARK: - Main View (Full-screen wrapper)

struct MediaDetailView: View {
    let media: PlexMetadata
    @EnvironmentObject var authService: PlexAuthService
    @Environment(\.dismiss) var dismiss

    // Data state
    @State private var detailedMedia: PlexMetadata?
    @State private var seasons: [PlexMetadata] = []
    @State private var allEpisodes: [PlexMetadata] = []
    @State private var selectedSeason: PlexMetadata?
    @State private var onDeckEpisode: PlexMetadata?
    @State private var trailers: [PlexMetadata] = []
    @State private var isLoading = true

    // Focus tracking for synopsis swap
    @State private var focusedEpisode: PlexMetadata?

    // Playback
    @State private var playMedia: PlexMetadata?

    // Content padding (same as original cardPadding)
    private let contentPadding: CGFloat = 48

    var body: some View {
        ZStack {
            // LAYER 1: Full-screen hero background (unblurred, not dimmed)
            heroBackdrop

            // LAYER 2: Bottom-to-middle gradient ONLY
            gradientOverlay

            // LAYER 3: Foreground detail content (reusing original layout)
            VStack(spacing: 0) {
                Spacer()

                MediaDetailContent(
                    media: displayMedia,
                    seasons: seasons,
                    allEpisodes: allEpisodes,
                    selectedSeason: $selectedSeason,
                    focusedEpisode: $focusedEpisode,
                    onDeckEpisode: onDeckEpisode,
                    trailers: trailers,
                    onPlay: handlePlay,
                    onPlayEpisode: { episode in playMedia = episode },
                    contentPadding: contentPadding
                )
                .environmentObject(authService)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .task { await loadDetails() }
        .fullScreenCover(item: $playMedia) { media in
            VideoPlayerView(media: media)
                .environmentObject(authService)
        }
        .onChange(of: playMedia) { oldValue, newValue in
            // Refresh episodes when returning from video playback
            if oldValue != nil && newValue == nil {
                print("📺 [MediaDetailView] Video player dismissed, refreshing episodes...")
                Task {
                    await refreshEpisodes()
                }
            }
        }
    }

    // MARK: - Hero Backdrop (Full-screen, unblurred, not globally dimmed)

    private var heroBackdrop: some View {
        Group {
            if let url = artworkURL(for: displayMedia.art) {
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.black
                }
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    // MARK: - Gradient Overlay (Multi-stop for better text readability)

    private var gradientOverlay: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.3), location: 0.5),
                .init(color: .black.opacity(0.6), location: 0.7),
                .init(color: .black.opacity(0.9), location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Computed Properties

    private var displayMedia: PlexMetadata {
        detailedMedia ?? media
    }

    private func artworkURL(for path: String?) -> URL? {
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url,
              let path = path else { return nil }
        var urlString = baseURL.absoluteString + path
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }
        return URL(string: urlString)
    }

    // MARK: - Actions

    private func handlePlay() {
        if displayMedia.type == "show" {
            if let episode = onDeckEpisode {
                playMedia = episode
            } else if let first = allEpisodes.first {
                playMedia = first
            }
        } else {
            playMedia = displayMedia
        }
    }

    // MARK: - Data Loading

    private func loadDetails() async {
        guard let client = authService.currentClient,
              let ratingKey = media.ratingKey else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            detailedMedia = try await client.getMetadata(ratingKey: ratingKey)

            if media.type == "show" {
                async let seasonsTask = client.getChildren(ratingKey: ratingKey)
                async let onDeckTask = client.getOnDeck()

                let (loadedSeasons, onDeckItems) = try await (seasonsTask, onDeckTask)
                seasons = loadedSeasons
                selectedSeason = seasons.first
                onDeckEpisode = onDeckItems.first { $0.grandparentRatingKey == ratingKey }

                await loadAllEpisodes(client: client)
            }

            if media.type == "movie" {
                if let extras = try? await client.getExtras(ratingKey: ratingKey) {
                    trailers = extras.filter {
                        $0.type == "clip" && $0.title.lowercased().contains("trailer")
                    }
                }
            }
        } catch {
            print("Error loading details: \(error)")
        }
    }

    private func loadAllEpisodes(client: PlexAPIClient) async {
        await withTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (index, season) in seasons.enumerated() {
                group.addTask {
                    guard let key = season.ratingKey,
                          let episodes = try? await client.getChildren(ratingKey: key)
                    else { return (index, []) }
                    return (index, episodes)
                }
            }

            var results: [(Int, [PlexMetadata])] = []
            for await result in group { results.append(result) }
            results.sort { $0.0 < $1.0 }
            allEpisodes = results.flatMap { $0.1 }
        }

        let urls = allEpisodes.compactMap { artworkURL(for: $0.thumb) }
        ImageCacheService.shared.prefetch(urls: urls)
    }

    /// Lightweight refresh of episodes after video playback to update progress bars
    private func refreshEpisodes() async {
        guard let client = authService.currentClient,
              let ratingKey = media.ratingKey,
              media.type == "show" else { return }

        do {
            // Refresh onDeck episode first (most likely to have changed)
            let onDeckItems = try await client.getOnDeck()
            onDeckEpisode = onDeckItems.first { $0.grandparentRatingKey == ratingKey }

            // Refresh all episodes to update progress bars
            await loadAllEpisodes(client: client)

            print("📺 [MediaDetailView] Episodes refreshed, onDeck: \(onDeckEpisode?.title ?? "none")")
        } catch {
            print("🔴 [MediaDetailView] Error refreshing episodes: \(error)")
        }
    }
}

// MARK: - MediaDetailContent
// Extracted inner layout from the original ShowDetailCard.
// All fonts, padding, spacing, gradients, and view order are UNCHANGED.
// Only the outer card wrapper (clipShape, background, fixed frame) was removed.

struct MediaDetailContent: View {
    let media: PlexMetadata
    let seasons: [PlexMetadata]
    let allEpisodes: [PlexMetadata]
    @Binding var selectedSeason: PlexMetadata?
    @Binding var focusedEpisode: PlexMetadata?
    let onDeckEpisode: PlexMetadata?
    let trailers: [PlexMetadata]
    let onPlay: () -> Void
    let onPlayEpisode: (PlexMetadata) -> Void
    let contentPadding: CGFloat

    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        // ORIGINAL INNER LAYOUT - unchanged from ShowDetailCard
        VStack(alignment: .leading, spacing: 0) {
            // HERO BLOCK: Logo + Metadata + Synopsis + Technical Details + Buttons
            // Positioned just above the season selector
            VStack(alignment: .leading, spacing: 12) {
                logoOrTitle
                metadataRow          // Type | Genre
                synopsisArea         // Description
                technicalDetailsRow  // Rating, Year, Runtime, Resolution, Audio
                actionButtons
            }
            .padding(.horizontal, contentPadding)

            // SEASON CHIPS + EPISODES ROW
            if media.type == "show" && !seasons.isEmpty {
                seasonChipsRow
                    .padding(.top, 20)
                    .padding(.horizontal, contentPadding)

                episodesRow
                    .padding(.top, 14)
                    .padding(.bottom, contentPadding - 6)
            } else {
                Spacer().frame(height: contentPadding)
            }
        }
        // REMOVED: .frame(width: cardWidth, height: cardHeight)
        // REMOVED: .background(ZStack { artwork + gradient })
        // REMOVED: .clipShape(RoundedRectangle(...))
        // REMOVED: .overlay(RoundedRectangle(...).strokeBorder(...))
    }

    // MARK: - Hero Components (ALL UNCHANGED)

    private var logoOrTitle: some View {
        Group {
            if let logo = media.clearLogo, let url = logoURL(for: logo) {
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    titleText
                }
                .frame(maxWidth: 600, maxHeight: 180, alignment: .leading)
                .shadow(color: .black.opacity(0.7), radius: 10, x: 0, y: 4)
            } else {
                titleText
            }
        }
    }

    private var titleText: some View {
        Text(media.title)
            .font(.system(size: 76, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.8), radius: 10, x: 0, y: 4)
    }

    // Row 1: Type | Genre
    private var metadataRow: some View {
        HStack(spacing: 10) {
            Text(media.type == "movie" ? "Movie" : "TV Show")
                .foregroundColor(.white)
                .fontWeight(.medium)

            if let genres = media.genre, let firstGenre = genres.first {
                Text("·").foregroundColor(.white.opacity(0.7))
                Text(firstGenre.tag)
                    .foregroundColor(.white)
            }
        }
        .font(.system(size: 24, weight: .medium))
        .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
    }

    // SYNOPSIS AREA - Fixed height, content swaps on episode focus
    private var synopsisArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let episode = focusedEpisode {
                episodeSynopsis(episode: episode)
            } else {
                showSynopsis
            }
        }
        .frame(height: 120, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.15), value: focusedEpisode?.id)
    }

    private var showSynopsis: some View {
        Text(media.summary ?? "")
            .font(.system(size: 24, weight: .regular))
            .foregroundColor(.white.opacity(0.9))
            .lineLimit(4)
            .frame(maxWidth: 1000, alignment: .leading)
            .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
    }

    // Row 2: Technical details (Year, Runtime, Resolution, Audio)
    private var technicalDetailsRow: some View {
        HStack(spacing: 10) {
            // Rating
            if let r = media.audienceRating {
                Text("★ \(String(format: "%.1f", r))")
                    .foregroundColor(.yellow)
            }

            // Content Rating (cleaned - removes /au suffix)
            if let c = media.contentRating {
                if media.audienceRating != nil { Text("·").foregroundColor(.white.opacity(0.6)) }
                Text(cleanedContentRating(c))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(4)
            }

            // Year
            if let y = media.year {
                Text("·").foregroundColor(.white.opacity(0.6))
                Text(String(y))
                    .foregroundColor(.white)
            }

            // Runtime
            if let d = media.duration {
                Text("·").foregroundColor(.white.opacity(0.6))
                Text(formatDuration(d))
                    .foregroundColor(.white)
            }

            // Resolution (movies only)
            if media.type == "movie", let resolution = mediaResolution {
                Text("·").foregroundColor(.white.opacity(0.6))
                Text(resolution)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
            }

            // Audio format (movies only)
            if media.type == "movie", let audio = mediaAudioFormat {
                Text("·").foregroundColor(.white.opacity(0.6))
                Text(audio)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: 20, weight: .medium))
        .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
    }

    /// Clean content rating by removing regional suffixes like "/au"
    private func cleanedContentRating(_ rating: String) -> String {
        rating.replacingOccurrences(of: "/au", with: "", options: .caseInsensitive)
    }

    // Get resolution from media info (UNCHANGED)
    private var mediaResolution: String? {
        guard let mediaInfo = media.media?.first,
              let resolution = mediaInfo.videoResolution else { return nil }

        switch resolution.lowercased() {
        case "4k", "2160": return "4K"
        case "1080": return "1080p"
        case "720": return "720p"
        case "480", "sd": return "SD"
        default: return resolution.uppercased()
        }
    }

    // Get audio format from media info (UNCHANGED)
    private var mediaAudioFormat: String? {
        guard let mediaInfo = media.media?.first,
              let codec = mediaInfo.audioCodec else { return nil }

        let channels = mediaInfo.audioChannels ?? 2
        let channelString = channels >= 6 ? " \(channels - 1).1" : ""

        switch codec.lowercased() {
        case "truehd": return "Dolby TrueHD\(channelString)"
        case "eac3": return "Dolby Digital+\(channelString)"
        case "ac3": return "Dolby Digital\(channelString)"
        case "dts": return "DTS\(channelString)"
        case "dca": return "DTS\(channelString)"
        case "dts-hd", "dtshd": return "DTS-HD\(channelString)"
        case "aac": return "AAC\(channelString)"
        case "flac": return "FLAC"
        default: return codec.uppercased()
        }
    }

    private func episodeSynopsis(episode: PlexMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let s = episode.parentIndex, let e = episode.index {
                    Text("S\(s), E\(e)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color.beaconPurple)
                }
                if let d = episode.duration {
                    Text("·").foregroundColor(.white.opacity(0.6))
                    Text(formatDuration(d))
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)

            Text(episode.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)

            Text(episode.summary ?? "")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: 1000, alignment: .leading)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
        }
    }

    // ACTION BUTTONS (UNCHANGED)
    private var actionButtons: some View {
        HStack(spacing: 14) {
            Button(action: onPlay) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(playButtonLabel)
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .buttonStyle(.borderedProminent)

            if media.type == "show" && !seasons.isEmpty {
                Button(action: {}) {
                    Image(systemName: "shuffle.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.bordered)
            }

            if media.type == "movie" && !trailers.isEmpty {
                Button(action: {}) {
                    HStack(spacing: 6) {
                        Image(systemName: "film.stack.fill")
                        Text("Trailer")
                    }
                    .font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(.bordered)
            }

            // Watch/Unwatch button for movies
            if media.type == "movie" {
                WatchStatusButton(media: media)
                    .environmentObject(authService)
            }
        }
    }

    private var playButtonLabel: String {
        if media.type == "show", let ep = onDeckEpisode {
            let s = ep.parentIndex ?? 1
            let e = ep.index ?? 1
            return ep.progress > 0 ? "Resume S\(s)E\(e)" : "Play S\(s)E\(e)"
        }
        return media.progress > 0 ? "Resume" : "Play"
    }

    // SEASON CHIPS ROW (no label) (UNCHANGED)
    private var seasonChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(seasons) { season in
                    SeasonChip(
                        season: season,
                        isSelected: selectedSeason?.id == season.id,
                        action: { selectedSeason = season }
                    )
                }
            }
        }
    }

    // EPISODES ROW (no label) (UNCHANGED)
    private var episodesRow: some View {
        EpisodesRow(
            episodes: allEpisodes,
            selectedSeason: selectedSeason,
            focusedEpisode: $focusedEpisode,
            onPlay: onPlayEpisode,
            horizontalPadding: contentPadding
        )
        .environmentObject(authService)
    }

    // MARK: - Helpers (UNCHANGED)

    private func artworkURL(for path: String?) -> URL? {
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url,
              let path = path else { return nil }
        var urlString = baseURL.absoluteString + path
        if let token = server.accessToken { urlString += "?X-Plex-Token=\(token)" }
        return URL(string: urlString)
    }

    private func logoURL(for logo: String) -> URL? {
        if logo.starts(with: "http") { return URL(string: logo) }
        return artworkURL(for: logo)
    }

    private func formatDuration(_ ms: Int) -> String {
        let mins = ms / 1000 / 60
        let hrs = mins / 60
        return hrs > 0 ? "\(hrs)h \(mins % 60)m" : "\(mins)m"
    }
}

// MARK: - Season Chip (UNCHANGED)

struct SeasonChip: View {
    let season: PlexMetadata
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(season.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.beaconPurple.opacity(0.8) : Color.white.opacity(0.1))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(isFocused ? 0.6 : 0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Episodes Row (UNCHANGED)

struct EpisodesRow: View {
    let episodes: [PlexMetadata]
    let selectedSeason: PlexMetadata?
    @Binding var focusedEpisode: PlexMetadata?
    let onPlay: (PlexMetadata) -> Void
    let horizontalPadding: CGFloat

    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 28) {
                    ForEach(episodes) { episode in
                        EpisodeThumbnail(
                            episode: episode,
                            onPlay: { onPlay(episode) },
                            onFocusChange: { focused in
                                if focused {
                                    focusedEpisode = episode
                                } else if focusedEpisode?.id == episode.id {
                                    focusedEpisode = nil
                                }
                            }
                        )
                        .id(episode.id)
                        .environmentObject(authService)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 20) // Accommodate scale effect and shadow overflow
            }
            .onAppear {
                if let first = episodes.first(where: { !$0.isWatched }) {
                    proxy.scrollTo(first.id, anchor: .leading)
                }
            }
            .onChange(of: selectedSeason) { _, newSeason in
                guard let season = newSeason else { return }
                if let first = episodes.first(where: { $0.parentRatingKey == season.ratingKey }) {
                    withAnimation { proxy.scrollTo(first.id, anchor: .leading) }
                }
            }
        }
    }
}

// MARK: - Episode Thumbnail (UNCHANGED)
// Matches MediaCard focus pattern: fixed size, single clipShape, scale+shadow only on focus

struct EpisodeThumbnail: View {
    let episode: PlexMetadata
    let onPlay: () -> Void
    let onFocusChange: (Bool) -> Void

    @FocusState private var isFocused: Bool
    @EnvironmentObject var authService: PlexAuthService

    // Fixed card dimensions - never changes with focus
    private let cardWidth: CGFloat = 280
    private let cardHeight: CGFloat = 158
    private let cornerRadius: CGFloat = DesignTokens.cornerRadiusMedium

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail card (clipped)
                ZStack {
                    // Layer 1: Thumbnail image
                    CachedAsyncImage(url: thumbnailURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay(Image(systemName: "tv").foregroundColor(.gray))
                    }
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()

                    // Layer 2: Progress bar (if applicable)
                    if episode.progress > 0 && episode.progress < 0.98 {
                        VStack {
                            Spacer()
                            ProgressBar(progress: episode.progress)
                                .frame(height: 4)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                    }

                    // Layer 3: Play overlay on focus (styling only)
                    if isFocused {
                        Color.black.opacity(0.2)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)
                    }
                }
                // Fixed frame - NEVER changes with focus
                .frame(width: cardWidth, height: cardHeight)
                // Single clipShape on the card
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                // Episode label (below card, like Continue Watching)
                VStack(alignment: .leading, spacing: 2) {
                    if let s = episode.parentIndex, let e = episode.index {
                        Text("S\(s) E\(e)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    Text(episode.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        // Focus effects: scale + shadow only (reduced scale to avoid overlap)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
            color: .black.opacity(isFocused ? 0.6 : 0.3),
            radius: isFocused ? 20 : 8,
            x: 0,
            y: isFocused ? 10 : 4
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isFocused)
        .buttonStyle(.plain)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange(focused)
        }
    }

    private var thumbnailURL: URL? {
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url,
              let thumb = episode.thumb else { return nil }
        var urlString = baseURL.absoluteString + thumb
        if let token = server.accessToken { urlString += "?X-Plex-Token=\(token)" }
        return URL(string: urlString)
    }
}

// MARK: - Progress Bar (UNCHANGED)

struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule()
                    .fill(Color.beaconPurple)
                    .frame(width: geo.size.width * progress)
            }
        }
    }
}

// MARK: - Watch Status Button (UNCHANGED)

struct WatchStatusButton: View {
    let media: PlexMetadata
    @EnvironmentObject var authService: PlexAuthService
    @State private var isWatched: Bool
    @State private var isUpdating = false

    init(media: PlexMetadata) {
        self.media = media
        self._isWatched = State(initialValue: media.isWatched)
    }

    var body: some View {
        Button {
            guard !isUpdating else { return }
            Task {
                await toggleWatched()
            }
        } label: {
            HStack(spacing: 6) {
                if isUpdating {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: isWatched ? "eye.slash.fill" : "eye.fill")
                }
                Text(isWatched ? "Unwatch" : "Watch")
            }
            .font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(.bordered)
        .disabled(isUpdating)
    }

    private func toggleWatched() async {
        guard let client = authService.currentClient,
              let ratingKey = media.ratingKey else { return }

        isUpdating = true
        defer { isUpdating = false }

        do {
            if isWatched {
                try await client.unscrobble(ratingKey: ratingKey)
            } else {
                try await client.scrobble(ratingKey: ratingKey)
            }
            isWatched.toggle()
        } catch {
            print("Error toggling watched status: \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    MediaDetailView(media: PlexMetadata(
        ratingKey: "1", key: "/library/metadata/1", guid: nil, studio: nil,
        type: "show", title: "Sample Show", titleSort: nil,
        librarySectionTitle: nil, librarySectionID: nil, librarySectionKey: nil,
        contentRating: "TV-MA", summary: "A thrilling drama series.", rating: nil,
        audienceRating: 8.7, year: 2024, tagline: nil, thumb: nil, art: nil,
        duration: 3600000, originallyAvailableAt: nil, addedAt: nil, updatedAt: nil,
        audienceRatingImage: nil, primaryExtraKey: nil, ratingImage: nil,
        viewOffset: nil, viewCount: nil, lastViewedAt: nil,
        grandparentRatingKey: nil, grandparentKey: nil, grandparentTitle: nil,
        grandparentThumb: nil, grandparentArt: nil, parentRatingKey: nil,
        parentKey: nil, parentTitle: nil, parentThumb: nil, parentIndex: nil,
        index: nil, childCount: nil, leafCount: nil, viewedLeafCount: nil,
        media: nil, role: nil, genre: nil, director: nil, writer: nil,
        country: nil, Image: nil
    ))
    .environmentObject(PlexAuthService())
}
