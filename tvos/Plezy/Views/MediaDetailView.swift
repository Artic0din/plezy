//
//  MediaDetailView.swift
//  Beacon tvOS
//
//  TV show detail view with:
//  - ONE fixed-size card (no card behind card)
//  - Card position NEVER moves when focus changes
//  - Synopsis swaps based on episode focus
//  - Single episodes row with all seasons
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

    // ═══════════════════════════════════════════════════════════════════════════
    // CARD DIMENSIONS - Fixed size, consistent across all shows
    // ═══════════════════════════════════════════════════════════════════════════
    private let cardWidth: CGFloat = 1720
    private let cardHeight: CGFloat = 900
    private let cardCornerRadius: CGFloat = 24
    private let cardPadding: CGFloat = 48

    var body: some View {
        // ═══════════════════════════════════════════════════════════════════════
        // ROOT ZSTACK - Card is centered and NEVER moves vertically
        // No ScrollView wrapper, no FocusSection that could auto-scroll
        // ═══════════════════════════════════════════════════════════════════════
        ZStack {
            // LAYER 1: Full-screen dimmed backdrop (NOT a card, just background)
            dimmedBackdrop

            // LAYER 2: The ONE and ONLY card - fixed position, centered
            ShowDetailCard(
                media: displayMedia,
                seasons: seasons,
                allEpisodes: allEpisodes,
                selectedSeason: $selectedSeason,
                focusedEpisode: $focusedEpisode,
                onDeckEpisode: onDeckEpisode,
                trailers: trailers,
                onPlay: handlePlay,
                onPlayEpisode: { episode in playMedia = episode },
                cardWidth: cardWidth,
                cardHeight: cardHeight,
                cardCornerRadius: cardCornerRadius,
                cardPadding: cardPadding
            )
            .environmentObject(authService)
            // Card is centered and position is LOCKED - never moves
            .position(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2)
        }
        .ignoresSafeArea()
        .task { await loadDetails() }
        .fullScreenCover(item: $playMedia) { media in
            VideoPlayerView(media: media)
                .environmentObject(authService)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DIMMED BACKDROP: Full-screen show artwork, dimmed (NOT a card)
    // This is NOT a rounded card - just a flat full-screen background
    // ═══════════════════════════════════════════════════════════════════════════
    private var dimmedBackdrop: some View {
        ZStack {
            Color.black

            if let url = artworkURL(for: displayMedia.art) {
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.black
                }
                .opacity(0.15)
            }
        }
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
}

// MARK: - ShowDetailCard
// ═══════════════════════════════════════════════════════════════════════════════
// THE ONE AND ONLY CARD on screen.
// - Fixed dimensions that NEVER change
// - Artwork background with gradient (inside the card, not behind it)
// - Layout: Hero block → Season chips → Episodes row
// - No extra rounded containers, no card-behind-card
// ═══════════════════════════════════════════════════════════════════════════════

struct ShowDetailCard: View {
    let media: PlexMetadata
    let seasons: [PlexMetadata]
    let allEpisodes: [PlexMetadata]
    @Binding var selectedSeason: PlexMetadata?
    @Binding var focusedEpisode: PlexMetadata?
    let onDeckEpisode: PlexMetadata?
    let trailers: [PlexMetadata]
    let onPlay: () -> Void
    let onPlayEpisode: (PlexMetadata) -> Void

    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cardCornerRadius: CGFloat
    let cardPadding: CGFloat

    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        // ═══════════════════════════════════════════════════════════════════════
        // SINGLE CARD STRUCTURE
        // ZStack: artwork background + content overlay
        // No nested cards, no extra RoundedRectangles
        // ═══════════════════════════════════════════════════════════════════════
        ZStack(alignment: .bottomLeading) {
            // Card background: artwork + gradient overlay
            artworkBackground

            // Card content: hero + season chips + episodes
            cardContent
        }
        // FIXED SIZE - dimensions never change regardless of content/focus
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ARTWORK BACKGROUND (inside the card, NOT a separate card behind)
    // ═══════════════════════════════════════════════════════════════════════════
    private var artworkBackground: some View {
        ZStack {
            // Show artwork
            if let url = artworkURL(for: media.art) {
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.black
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
            } else {
                Color.black
            }

            // Gradient overlay for text readability
            LinearGradient(
                colors: [
                    Color.black.opacity(0.4),
                    Color.black.opacity(0.7),
                    Color.black.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CARD CONTENT LAYOUT
    // Vertical order (top to bottom):
    //   1. Logo/Title
    //   2. Media details (type, rating, year, runtime)
    //   3. Synopsis/description (swaps on episode focus)
    //   4. Action buttons
    //   5. Season selector chips (NO label)
    //   6. Episodes row (NO label)
    // ═══════════════════════════════════════════════════════════════════════════
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            // HERO BLOCK: grouped together, positioned just above season chips
            VStack(alignment: .leading, spacing: 12) {
                logoOrTitle
                metadataRow
                synopsisArea
                actionButtons
            }
            .padding(.horizontal, cardPadding)

            // SEASON CHIPS (no label, directly under hero)
            if media.type == "show" && !seasons.isEmpty {
                seasonChipsRow
                    .padding(.top, 20)
                    .padding(.horizontal, cardPadding)

                // EPISODES ROW (no label, directly under chips)
                episodesRow
                    .padding(.top, 14)
                    .padding(.bottom, cardPadding - 6)
            } else {
                Spacer().frame(height: cardPadding)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HERO COMPONENTS
    // ═══════════════════════════════════════════════════════════════════════════

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
                .frame(maxWidth: 400, maxHeight: 100, alignment: .leading)
            } else {
                titleText
            }
        }
    }

    private var titleText: some View {
        Text(media.title)
            .font(.system(size: 40, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(2)
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            Text(media.type == "movie" ? "Movie" : "TV Show")
                .foregroundColor(.white.opacity(0.7))

            ForEach(metadataChips, id: \.self) { chip in
                Text("·").foregroundColor(.white.opacity(0.4))
                Text(chip).foregroundColor(.white.opacity(0.7))
            }
        }
        .font(.system(size: 18, weight: .medium))
    }

    private var metadataChips: [String] {
        var chips: [String] = []
        if let r = media.audienceRating { chips.append("★ \(String(format: "%.1f", r))") }
        if let c = media.contentRating { chips.append(c) }
        if let y = media.year { chips.append(String(y)) }
        if let d = media.duration { chips.append(formatDuration(d)) }
        return chips
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNOPSIS AREA
    // - Shows series synopsis when no episode is focused
    // - Shows episode info when an episode is focused
    // - Fixed height to prevent layout shift
    // ═══════════════════════════════════════════════════════════════════════════
    private var synopsisArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let episode = focusedEpisode {
                episodeSynopsis(episode: episode)
            } else {
                showSynopsis
            }
        }
        .frame(height: 100, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.15), value: focusedEpisode?.id)
    }

    private var showSynopsis: some View {
        Text(media.summary ?? "")
            .font(.system(size: 18))
            .foregroundColor(.white.opacity(0.75))
            .lineLimit(4)
            .frame(maxWidth: 800, alignment: .leading)
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
                    Text("·").foregroundColor(.white.opacity(0.4))
                    Text(formatDuration(d))
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            Text(episode.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(episode.summary ?? "")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(2)
                .frame(maxWidth: 800, alignment: .leading)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ACTION BUTTONS
    // ═══════════════════════════════════════════════════════════════════════════
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
            .buttonStyle(.clearGlass)

            if media.type == "show" && !seasons.isEmpty {
                Button(action: {}) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }
                .buttonStyle(CardButtonStyle())
            }

            if media.type == "movie" && !trailers.isEmpty {
                Button(action: {}) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle")
                        Text("Trailer")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                }
                .buttonStyle(CardButtonStyle())
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

    // ═══════════════════════════════════════════════════════════════════════════
    // SEASON CHIPS ROW (NO "Season" label)
    // ═══════════════════════════════════════════════════════════════════════════
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

    // ═══════════════════════════════════════════════════════════════════════════
    // EPISODES ROW (NO "Episodes" label)
    // All episodes from all seasons in one horizontal row
    // Season chip selection scrolls to that season's first episode
    // ═══════════════════════════════════════════════════════════════════════════
    private var episodesRow: some View {
        EpisodesRow(
            episodes: allEpisodes,
            selectedSeason: selectedSeason,
            focusedEpisode: $focusedEpisode,
            onPlay: onPlayEpisode,
            horizontalPadding: cardPadding
        )
        .environmentObject(authService)
    }

    // MARK: - Helpers

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

// MARK: - Season Chip

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
                HStack(spacing: 16) {
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
                .padding(.vertical, 6)
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

    private let thumbWidth: CGFloat = 280
    private let thumbHeight: CGFloat = 158

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                // Thumbnail image
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
                    .frame(width: thumbWidth, height: thumbHeight)
                    .clipped()

                    // Progress bar
                    if episode.progress > 0 && episode.progress < 0.98 {
                        VStack {
                            Spacer()
                            ProgressBar(progress: episode.progress)
                                .frame(height: 3)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                    }

                    // Play overlay on focus
                    if isFocused {
                        Color.black.opacity(0.25)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                            .shadow(radius: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

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
                .frame(width: thumbWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(
            color: isFocused ? Color.beaconPurple.opacity(0.4) : .clear,
            radius: isFocused ? 12 : 0,
            y: isFocused ? 6 : 0
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
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
