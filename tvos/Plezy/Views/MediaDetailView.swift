//
//  MediaDetailView.swift
//  Beacon tvOS
//
//  Full-screen hero detail view with:
//  - Full-screen backdrop artwork (no card container)
//  - Bottom-to-middle gradient for text readability
//  - Left-aligned info panel in lower-left portion
//  - Episode row at bottom for TV shows
//

import SwiftUI

// MARK: - Main View

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

    var body: some View {
        ZStack {
            // LAYER 1: Full-screen hero backdrop
            heroBackdrop

            // LAYER 2: Bottom-to-middle gradient overlay
            gradientOverlay

            // LAYER 3: Content layer - left-aligned info panel
            contentLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .task { await loadDetails() }
        .fullScreenCover(item: $playMedia) { media in
            VideoPlayerView(media: media)
                .environmentObject(authService)
        }
        .onChange(of: playMedia) { oldValue, newValue in
            if oldValue != nil && newValue == nil {
                print("📺 [MediaDetailView] Video player dismissed, refreshing episodes...")
                Task {
                    await refreshEpisodes()
                }
            }
        }
    }

    // MARK: - Hero Backdrop (Full-screen, unblurred, not dimmed)

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

    // MARK: - Gradient Overlay (Bottom-to-middle only)

    private var gradientOverlay: some View {
        VStack(spacing: 0) {
            // Top half: completely transparent
            Color.clear
                .frame(maxHeight: .infinity)

            // Bottom half: gradient from transparent to dark
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.4),
                    Color.black.opacity(0.75),
                    Color.black.opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    // MARK: - Content Layer (Left-aligned info panel)

    private var contentLayer: some View {
        VStack(spacing: 0) {
            Spacer()

            // Main content: left-aligned info + spacer to push content left
            HStack(alignment: .bottom, spacing: 0) {
                // Left info panel
                InfoPanel(
                    media: displayMedia,
                    focusedEpisode: focusedEpisode,
                    onDeckEpisode: onDeckEpisode,
                    trailers: trailers,
                    onPlay: handlePlay
                )
                .environmentObject(authService)

                Spacer()
            }
            .padding(.horizontal, 80)
            .padding(.bottom, displayMedia.type == "show" && !seasons.isEmpty ? 20 : 80)

            // TV Show: Season chips + Episodes row at the bottom
            if displayMedia.type == "show" && !seasons.isEmpty {
                VStack(spacing: 14) {
                    seasonChipsRow
                    episodesRow
                }
                .padding(.bottom, 40)
            }
        }
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

    // MARK: - Season/Episode Rows

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
            .padding(.horizontal, 80)
        }
    }

    private var episodesRow: some View {
        EpisodesRow(
            episodes: allEpisodes,
            selectedSeason: selectedSeason,
            focusedEpisode: $focusedEpisode,
            onPlay: { episode in playMedia = episode },
            horizontalPadding: 80
        )
        .environmentObject(authService)
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

    private func refreshEpisodes() async {
        guard let client = authService.currentClient,
              let ratingKey = media.ratingKey,
              media.type == "show" else { return }

        do {
            let onDeckItems = try await client.getOnDeck()
            onDeckEpisode = onDeckItems.first { $0.grandparentRatingKey == ratingKey }
            await loadAllEpisodes(client: client)
            print("📺 [MediaDetailView] Episodes refreshed, onDeck: \(onDeckEpisode?.title ?? "none")")
        } catch {
            print("🔴 [MediaDetailView] Error refreshing episodes: \(error)")
        }
    }
}

// MARK: - Info Panel (Left-aligned content)

struct InfoPanel: View {
    let media: PlexMetadata
    let focusedEpisode: PlexMetadata?
    let onDeckEpisode: PlexMetadata?
    let trailers: [PlexMetadata]
    let onPlay: () -> Void

    @EnvironmentObject var authService: PlexAuthService

    // Max width for the info panel (roughly left third of screen)
    private let maxInfoWidth: CGFloat = 700

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title / Logo
            logoOrTitle

            // Metadata row (type, rating, year, runtime, etc.)
            metadataRow

            // Synopsis (swaps on episode focus for TV shows)
            synopsisArea

            // Action buttons
            actionButtons
        }
        .frame(maxWidth: maxInfoWidth, alignment: .leading)
    }

    // MARK: - Logo / Title

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
                .frame(maxWidth: 420, maxHeight: 120, alignment: .leading)
            } else {
                titleText
            }
        }
    }

    private var titleText: some View {
        Text(media.title)
            .font(.system(size: 48, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
    }

    // MARK: - Metadata Row

    private var metadataRow: some View {
        HStack(spacing: 10) {
            // Content type
            Text(media.type == "movie" ? "Movie" : "TV Show")
                .foregroundColor(.white.opacity(0.9))
                .fontWeight(.semibold)

            // Genre
            if let genres = media.genre, let firstGenre = genres.first {
                Text("·").foregroundColor(.white.opacity(0.5))
                Text(firstGenre.tag)
                    .foregroundColor(.white.opacity(0.8))
            }

            // Rating
            if let r = media.audienceRating {
                Text("·").foregroundColor(.white.opacity(0.5))
                Text("★ \(String(format: "%.1f", r))")
                    .foregroundColor(.yellow)
            }

            // Content Rating
            if let c = media.contentRating {
                Text("·").foregroundColor(.white.opacity(0.5))
                Text(c)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(4)
            }

            // Year
            if let y = media.year {
                Text("·").foregroundColor(.white.opacity(0.5))
                Text(String(y))
                    .foregroundColor(.white.opacity(0.8))
            }

            // Runtime
            if let d = media.duration {
                Text("·").foregroundColor(.white.opacity(0.5))
                Text(formatDuration(d))
                    .foregroundColor(.white.opacity(0.8))
            }

            // Resolution (movies only)
            if media.type == "movie", let resolution = mediaResolution {
                Text("·").foregroundColor(.white.opacity(0.5))
                Text(resolution)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
            }

            // Audio format (movies only)
            if media.type == "movie", let audio = mediaAudioFormat {
                Text("·").foregroundColor(.white.opacity(0.5))
                Text(audio)
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: 18, weight: .medium))
        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
    }

    // Resolution from media info
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

    // Audio format from media info
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

    // MARK: - Synopsis Area

    private var synopsisArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let episode = focusedEpisode {
                episodeSynopsis(episode: episode)
            } else {
                showSynopsis
            }
        }
        .frame(height: 110, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.15), value: focusedEpisode?.id)
    }

    private var showSynopsis: some View {
        Text(media.summary ?? "")
            .font(.system(size: 18))
            .foregroundColor(.white.opacity(0.85))
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
    }

    private func episodeSynopsis(episode: PlexMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let s = episode.parentIndex, let e = episode.index {
                    Text("S\(s), E\(e)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color.beaconPurple)
                }
                if let d = episode.duration {
                    Text("·").foregroundColor(.white.opacity(0.5))
                    Text(formatDuration(d))
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            Text(episode.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(episode.summary ?? "")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(2)
        }
        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            // Play button
            Button(action: onPlay) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(playButtonLabel)
                        .font(.system(size: 20, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .buttonStyle(.clearGlass)

            // Shuffle (TV shows only)
            if media.type == "show" {
                Button(action: {}) {
                    Image(systemName: "shuffle.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }
                .buttonStyle(CardButtonStyle())
            }

            // Trailer (movies only)
            if media.type == "movie" && !trailers.isEmpty {
                Button(action: {}) {
                    HStack(spacing: 6) {
                        Image(systemName: "film.stack.fill")
                        Text("Trailer")
                    }
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                }
                .buttonStyle(CardButtonStyle())
            }

            // Watch/Unwatch (movies only)
            if media.type == "movie" {
                WatchStatusButton(media: media)
                    .environmentObject(authService)
            }
        }
        .padding(.top, 8)
    }

    private var playButtonLabel: String {
        if media.type == "show", let ep = onDeckEpisode {
            let s = ep.parentIndex ?? 1
            let e = ep.index ?? 1
            return ep.progress > 0 ? "Resume S\(s)E\(e)" : "Play S\(s)E\(e)"
        }
        return media.progress > 0 ? "Resume" : "Play"
    }

    // MARK: - Helpers

    private func logoURL(for logo: String) -> URL? {
        if logo.starts(with: "http") { return URL(string: logo) }
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url else { return nil }
        var urlString = baseURL.absoluteString + logo
        if let token = server.accessToken { urlString += "?X-Plex-Token=\(token)" }
        return URL(string: urlString)
    }

    private func formatDuration(_ ms: Int) -> String {
        let mins = ms / 1000 / 60
        let hrs = mins / 60
        return hrs > 0 ? "\(hrs)h \(mins % 60)m" : "\(mins)m"
    }
}

// MARK: - Season Chip

struct SeasonChip: View {
    let season: PlexMetadata
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(season.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isSelected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.beaconPurple.opacity(0.8) : Color.white.opacity(0.15))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(isFocused ? 0.6 : 0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Episodes Row

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
                .padding(.vertical, 20)
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

// MARK: - Episode Thumbnail

struct EpisodeThumbnail: View {
    let episode: PlexMetadata
    let onPlay: () -> Void
    let onFocusChange: (Bool) -> Void

    @FocusState private var isFocused: Bool
    @EnvironmentObject var authService: PlexAuthService

    private let cardWidth: CGFloat = 280
    private let cardHeight: CGFloat = 158
    private let cornerRadius: CGFloat = DesignTokens.cornerRadiusMedium

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail card
                ZStack {
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

                    // Progress bar
                    if episode.progress > 0 && episode.progress < 0.98 {
                        VStack {
                            Spacer()
                            ProgressBar(progress: episode.progress)
                                .frame(height: 4)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                    }

                    // Play overlay on focus
                    if isFocused {
                        Color.black.opacity(0.2)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                // Episode label
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
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
            color: .black.opacity(isFocused ? 0.6 : 0.3),
            radius: isFocused ? 20 : 8,
            x: 0,
            y: isFocused ? 10 : 4
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isFocused)
        .buttonStyle(MediaCardButtonStyle())
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

// MARK: - Progress Bar

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

// MARK: - Watch Status Button

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
                        .tint(.white)
                } else {
                    Image(systemName: isWatched ? "eye.slash.fill" : "eye.fill")
                }
                Text(isWatched ? "Unwatch" : "Watch")
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(.white)
        }
        .buttonStyle(CardButtonStyle())
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
