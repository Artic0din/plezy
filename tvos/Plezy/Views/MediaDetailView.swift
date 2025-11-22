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
    @State private var allEpisodes: [PlexMetadata] = []
    @State private var selectedSeason: PlexMetadata?
    @State private var onDeckEpisode: PlexMetadata?
    @State private var isLoading = true
    @State private var playMedia: PlexMetadata?
    @State private var trailers: [PlexMetadata] = []
    @State private var focusedEpisode: PlexMetadata?

    var body: some View {
        ZStack {
            // Plain black background (no blur, no artwork here)
            Color.black.ignoresSafeArea()

            // Single unified ShowDetailCard with artwork background
            showDetailCard
        }
        .ignoresSafeArea()
        .task {
            await loadDetails()
        }
        .fullScreenCover(item: $playMedia) { mediaToPlay in
            VideoPlayerView(media: mediaToPlay)
                .environmentObject(authService)
        }
    }

    // MARK: - Single Unified ShowDetailCard

    /// One unified card with show artwork as background, containing ALL content
    private var showDetailCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Info section (swaps between show and episode details)
            infoSection
                .padding(.horizontal, 60)
                .padding(.top, 50)
                .padding(.bottom, 30)

            // Season selector and episodes (for TV shows)
            if displayMedia.type == "show" && !seasons.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.horizontal, 60)

                // Season selector
                seasonSelector
                    .padding(.horizontal, 60)
                    .padding(.top, 24)

                // Episodes row (all episodes from all seasons)
                if !allEpisodes.isEmpty {
                    episodesRow
                        .padding(.top, 16)
                        .padding(.bottom, 30)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Single card background: artwork with gradient overlay
            ZStack {
                // Show artwork as card background
                if let artURL = artworkURL {
                    CachedAsyncImage(url: artURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Color.black
                    }
                } else {
                    Color.black
                }

                // Gradient overlay for text readability
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.7),
                        Color.black.opacity(0.85),
                        Color.black.opacity(0.95)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
    }

    // MARK: - Info Section (Swaps between Show and Episode details)

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let episode = focusedEpisode {
                episodeInfoView(episode: episode)
            } else {
                showInfoView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: focusedEpisode?.id)
    }

    /// Episode details view (shown when an episode is focused)
    private func episodeInfoView(episode: PlexMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Episode label
            if let seasonNum = episode.parentIndex, let episodeNum = episode.index {
                Text("S\(seasonNum), E\(episodeNum)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color.beaconPurple)
            }

            // Episode title
            Text(episode.title)
                .font(.system(size: 38, weight: .heavy))
                .foregroundColor(.white)
                .lineLimit(2)

            // Episode metadata
            HStack(spacing: 10) {
                if let duration = episode.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                if episode.progress > 0 && episode.progress < 0.98 {
                    Text("·")
                        .foregroundColor(.white.opacity(0.5))
                    Text("\(Int(episode.progress * 100))% watched")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            // Episode synopsis
            if let summary = episode.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Play button for episode
            HStack(spacing: 16) {
                Button {
                    playMedia = episode
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(episode.progress > 0 ? "Resume" : "Play Episode")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(.clearGlass)
            }
            .padding(.top, 4)
        }
    }

    /// Show/Series details view (shown when no episode is focused)
    private var showInfoView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Clear logo or title
            if let clearLogo = displayMedia.clearLogo, let logoURL = logoURL(for: clearLogo) {
                CachedAsyncImage(url: logoURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    Text(displayMedia.title)
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: 450, maxHeight: 120, alignment: .leading)
            } else {
                Text(displayMedia.title)
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }

            // Metadata chips
            HStack(spacing: 10) {
                Text(displayMedia.type == "movie" ? "Movie" : "TV Show")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                ForEach(metadataComponents, id: \.self) { component in
                    Text("·")
                        .foregroundColor(.white.opacity(0.5))
                    Text(component)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            // Summary
            if let summary = displayMedia.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action buttons
            HStack(spacing: 16) {
                Button {
                    handlePlayButton()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(playButtonLabel)
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(.clearGlass)

                if displayMedia.type == "show" && !seasons.isEmpty {
                    Button {
                        handleShufflePlay()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(CardButtonStyle())
                }

                if displayMedia.type == "movie" && !trailers.isEmpty {
                    Button {
                        handleTrailerPlay()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 16))
                            Text("Trailer")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(CardButtonStyle())
                }

                Button {
                    Task { await toggleWatched() }
                } label: {
                    Image(systemName: displayMedia.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(CardButtonStyle())
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Season Selector

    private var seasonSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Season")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(seasons) { season in
                        SeasonButton(
                            season: season,
                            isSelected: selectedSeason?.id == season.id
                        ) {
                            selectedSeason = season
                        }
                    }
                }
            }
        }
    }

    // MARK: - Episodes Row (All Episodes - NO clipping on left/right)

    private var episodesRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Episodes")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 60)

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(allEpisodes) { episode in
                            EpisodeCard(
                                episode: episode,
                                action: { playMedia = episode },
                                onFocusChange: { focused in
                                    if focused {
                                        focusedEpisode = episode
                                    } else if focusedEpisode?.id == episode.id {
                                        focusedEpisode = nil
                                    }
                                }
                            )
                            .id(episode.id)
                        }
                    }
                    .padding(.horizontal, 60)  // Inner padding so cards aren't cut off
                    .padding(.vertical, 8)
                }
                .onAppear {
                    scrollToFirstUnwatched(proxy: scrollProxy)
                }
                .onChange(of: selectedSeason) { _, newSeason in
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

    private var playButtonLabel: String {
        if displayMedia.type == "show" {
            if let episode = onDeckEpisode {
                let s = episode.parentIndex ?? 1
                let e = episode.index ?? 1
                return episode.progress > 0 ? "Resume S\(s)E\(e)" : "Play S\(s)E\(e)"
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
              let art = displayMedia.art else { return nil }
        var urlString = baseURL.absoluteString + art
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }
        return URL(string: urlString)
    }

    private func logoURL(for clearLogo: String) -> URL? {
        if clearLogo.starts(with: "http") { return URL(string: clearLogo) }
        guard let server = authService.selectedServer,
              let connection = server.connections.first,
              let baseURL = connection.url else { return nil }
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
        print("🔀 Shuffle play: \(displayMedia.title)")
    }

    private func handleTrailerPlay() {
        if let trailer = trailers.first {
            playMedia = trailer
        }
    }

    // MARK: - Data Loading

    private func loadDetails() async {
        guard let client = authService.currentClient,
              let ratingKey = media.ratingKey else { return }

        isLoading = true

        do {
            let detailed = try await client.getMetadata(ratingKey: ratingKey)
            detailedMedia = detailed

            if media.type == "show" {
                async let seasonsTask = client.getChildren(ratingKey: ratingKey)
                async let onDeckTask = client.getOnDeck()

                let (loadedSeasons, onDeckItems) = try await (seasonsTask, onDeckTask)
                seasons = loadedSeasons

                if let firstSeason = seasons.first {
                    selectedSeason = firstSeason
                }

                onDeckEpisode = onDeckItems.first { $0.grandparentRatingKey == ratingKey }

                await loadAllEpisodes()
            }

            if media.type == "movie" {
                do {
                    let extras = try await client.getExtras(ratingKey: ratingKey)
                    trailers = extras.filter {
                        $0.type == "clip" && ($0.title.lowercased().contains("trailer") || $0.summary?.lowercased().contains("trailer") == true)
                    }
                } catch {
                    trailers = []
                }
            }
        } catch {
            print("Error loading details: \(error)")
        }

        isLoading = false
    }

    private func loadAllEpisodes() async {
        guard let client = authService.currentClient else { return }

        var episodes: [PlexMetadata] = []

        await withTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (index, season) in seasons.enumerated() {
                group.addTask {
                    guard let seasonRatingKey = season.ratingKey else { return (index, []) }
                    do {
                        let seasonEpisodes = try await client.getChildren(ratingKey: seasonRatingKey)
                        return (index, seasonEpisodes)
                    } catch {
                        return (index, [])
                    }
                }
            }

            var results: [(Int, [PlexMetadata])] = []
            for await result in group {
                results.append(result)
            }

            results.sort { $0.0 < $1.0 }
            for (_, seasonEpisodes) in results {
                episodes.append(contentsOf: seasonEpisodes)
            }
        }

        allEpisodes = episodes

        let thumbnailURLs = allEpisodes.compactMap { episodeThumbnailURL(for: $0) }
        ImageCacheService.shared.prefetch(urls: thumbnailURLs)
    }

    private func toggleWatched() async {
        guard let client = authService.currentClient,
              let ratingKey = displayMedia.ratingKey else { return }
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
              let thumb = episode.thumb else { return nil }
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
        }
        return "\(minutes)m"
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
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
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

// MARK: - Episode Card

struct EpisodeCard: View {
    let episode: PlexMetadata
    let action: () -> Void
    let onFocusChange: (Bool) -> Void
    @FocusState private var isFocused: Bool
    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail
                ZStack {
                    CachedAsyncImage(url: thumbnailURL) { image in
                        image
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "tv")
                                    .font(.title)
                                    .foregroundColor(.gray)
                            )
                    }
                    .frame(width: 320, height: 180)

                    // Progress bar
                    if episode.progress > 0 && episode.progress < 0.98 {
                        VStack {
                            Spacer()
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.3))
                                    Capsule()
                                        .fill(Color.beaconPurple)
                                        .frame(width: geo.size.width * episode.progress)
                                }
                            }
                            .frame(height: 4)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                        }
                    }

                    // Play icon on focus
                    if isFocused {
                        Color.black.opacity(0.3)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.white)
                            .shadow(radius: 6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Episode info
                VStack(alignment: .leading, spacing: 2) {
                    if let s = episode.parentIndex, let e = episode.index {
                        Text("S\(s) E\(e)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    Text(episode.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .frame(width: 320, alignment: .leading)
                }
                .padding(.top, 8)
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .shadow(color: isFocused ? Color.beaconPurple.opacity(0.4) : .clear, radius: isFocused ? 12 : 0, y: isFocused ? 6 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
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
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }
        return URL(string: urlString)
    }
}

#Preview {
    MediaDetailView(media: PlexMetadata(
        ratingKey: "1", key: "/library/metadata/1", guid: nil, studio: nil,
        type: "show", title: "Sample Show", titleSort: nil,
        librarySectionTitle: nil, librarySectionID: nil, librarySectionKey: nil,
        contentRating: "TV-MA", summary: "A great show.", rating: nil,
        audienceRating: 8.5, year: 2024, tagline: nil, thumb: nil, art: nil,
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
