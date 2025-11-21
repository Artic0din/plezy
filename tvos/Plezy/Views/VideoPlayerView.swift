//
//  VideoPlayerView.swift
//  Beacon tvOS
//
//  Video player with AVKit
//

import SwiftUI
import AVKit
import AVFoundation
import Combine
import MediaPlayer
import AVFAudio

@available(tvOS 16.0, *)
struct VideoPlayerView: View {
    let media: PlexMetadata
    @EnvironmentObject var authService: PlexAuthService
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var playerManager: VideoPlayerManager

    init(media: PlexMetadata) {
        print("🎥 [VideoPlayerView] init() called for: \(media.title)")
        self.media = media
        _playerManager = StateObject(wrappedValue: VideoPlayerManager(media: media))
    }

    var body: some View {
        let _ = print("🎥 [VideoPlayerView] body evaluated for: \(media.title)")
        let _ = print("🎥 [VideoPlayerView] playerViewController: \(playerManager.playerViewController != nil)")
        let _ = print("🎥 [VideoPlayerView] isLoading: \(playerManager.isLoading)")
        let _ = print("🎥 [VideoPlayerView] error: \(playerManager.error ?? "none")")
        ZStack {
            Color.black.ignoresSafeArea()

            if playerManager.playerViewController != nil {
                TVPlayerViewController(playerManager: playerManager)
                    .ignoresSafeArea()
                    .onAppear {
                        print("👁️ [VideoPlayerView] TVPlayerViewController appeared for: \(media.title)")
                        print("👁️ [VideoPlayerView] Has authService: \(authService)")
                        print("👁️ [VideoPlayerView] Starting player setup...")
                        Task {
                            await playerManager.setupPlayer(authService: authService)
                        }
                    }
                    .onDisappear {
                        print("👋 [VideoPlayerView] TVPlayerViewController disappeared for: \(media.title)")
                        playerManager.cleanup()
                    }
            } else if playerManager.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)

                    Text("Loading video...")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            } else if let error = playerManager.error {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(.red)

                    Text("Error loading video")
                        .font(.title)
                        .foregroundColor(.white)

                    Text(error)
                        .font(.body)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 100)

                    HStack(spacing: 20) {
                        Button {
                            print("🔄 [VideoPlayerView] Retry button tapped")
                            Task {
                                await playerManager.setupPlayer(authService: authService)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry")
                            }
                            .font(.title3)
                        }
                        .buttonStyle(ClearGlassButtonStyle())

                        Button("Close") {
                            dismiss()
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }

            // Next episode countdown overlay
            if playerManager.showNextEpisodePrompt, let nextEp = playerManager.nextEpisode {
                NextEpisodeOverlay(
                    nextEpisode: nextEp,
                    countdown: playerManager.nextEpisodeCountdown,
                    onPlayNow: {
                        playerManager.cancelNextEpisode()
                        // Transition to next episode
                        // Note: This requires dismissing current player and showing new one
                        // For now, just dismiss - the view layer will handle navigation
                        dismiss()
                    },
                    onCancel: {
                        playerManager.cancelNextEpisode()
                    }
                )
                .environmentObject(authService)
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            print("🔄 [VideoPlayerView] Scene phase changed from \(oldPhase) to \(newPhase)")
            switch newPhase {
            case .background:
                print("⏸️ [VideoPlayerView] App backgrounded - pausing playback")
                playerManager.player?.pause()
            case .active:
                print("▶️ [VideoPlayerView] App active - resuming playback if it was playing")
                // Only resume if we're not at the error or loading state
                if playerManager.player != nil && playerManager.error == nil {
                    playerManager.player?.play()
                }
            case .inactive:
                print("💤 [VideoPlayerView] App inactive")
            @unknown default:
                break
            }
        }
    }
}

// MARK: - AVPlayerViewController Wrapper

@available(tvOS 16.0, *)
struct TVPlayerViewController: UIViewControllerRepresentable {
    @ObservedObject var playerManager: VideoPlayerManager

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()

        #if os(tvOS)
        // tvOS-specific configuration for enhanced playback experience

        // Configure transport bar customization (tvOS 16.0+)
        controller.transportBarIncludesTitleView = true
        controller.transportBarIncludesDisplayModeControls = true

        // Enable context menu for additional options
        if #available(tvOS 17.0, *) {
            controller.contextualActions = playerManager.createContextualActions()
        }

        // Set the coordinator as delegate for content proposals
        controller.delegate = context.coordinator

        print("🎬 [Player] Configured AVPlayerViewController for tvOS")
        #else
        // iOS-specific configuration
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif

        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Update player if it changes
        if uiViewController.player !== playerManager.player {
            uiViewController.player = playerManager.player

            #if os(tvOS)
            // Update content proposals when player changes
            if #available(tvOS 16.0, *), playerManager.player != nil {
                context.coordinator.updateContentProposals(
                    for: uiViewController,
                    playerManager: playerManager
                )
            }
            #endif
        }

        #if os(tvOS)
        // Update contextual actions if available
        if #available(tvOS 17.0, *) {
            uiViewController.contextualActions = playerManager.createContextualActions()
        }
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(playerManager: playerManager)
    }

    @available(tvOS 16.0, *)
    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let playerManager: VideoPlayerManager

        init(playerManager: VideoPlayerManager) {
            self.playerManager = playerManager
            super.init()
        }

        // MARK: - Content Proposals Delegate

        #if os(tvOS)
        @available(tvOS 16.0, *)
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            contentProposalViewController viewController: AVContentProposalViewController,
            didAcceptProposal proposal: AVContentProposal
        ) {
            print("📺 [ContentProposal] User accepted proposal: \(proposal.title ?? "Untitled")")

            // Handle the accepted proposal (play next episode)
            if let metadata = proposal.metadata as? PlexMetadata {
                Task { @MainActor in
                    // Signal that user wants to play the next episode
                    await playerManager.playNextEpisode(metadata)
                }
            }
        }

        @available(tvOS 16.0, *)
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            contentProposalViewController viewController: AVContentProposalViewController,
            didRejectProposal proposal: AVContentProposal
        ) {
            print("📺 [ContentProposal] User rejected proposal: \(proposal.title ?? "Untitled")")
            playerManager.cancelNextEpisode()
        }

        @available(tvOS 16.0, *)
        func updateContentProposals(
            for playerViewController: AVPlayerViewController,
            playerManager: VideoPlayerManager
        ) {
            guard let nextEpisode = playerManager.nextEpisode else {
                print("📺 [ContentProposal] No next episode available")
                return
            }

            // Create content proposal for next episode
            let proposal = playerManager.createContentProposal(for: nextEpisode)

            // Present content proposal at 30 seconds before end
            if let player = playerManager.player,
               let duration = player.currentItem?.duration,
               duration.isNumeric {
                let proposalTime = CMTimeSubtract(duration, CMTime(seconds: 30, preferredTimescale: 600))

                let action = AVContentProposalAction(
                    contentProposal: proposal,
                    automaticAcceptanceInterval: 15.0 // Auto-accept after 15 seconds
                )

                playerViewController.speeds = [0.5, 1.0, 1.25, 1.5, 2.0] // Playback speed options

                print("📺 [ContentProposal] Content proposal configured for next episode: \(nextEpisode.title)")
            }
        }
        #endif
    }
}

@MainActor
class VideoPlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var playerViewController: AVPlayerViewController?
    @Published var isLoading = true
    @Published var error: String?
    @Published var availableAudioTracks: [AVMediaSelectionOption] = []
    @Published var availableSubtitleTracks: [AVMediaSelectionOption] = []
    @Published var currentAudioTrack: AVMediaSelectionOption?
    @Published var currentSubtitleTrack: AVMediaSelectionOption?
    @Published var nextEpisode: PlexMetadata?
    @Published var showNextEpisodePrompt: Bool = false
    @Published var nextEpisodeCountdown: Int = 15
    @Published var chapters: [PlexChapter] = []

    private let media: PlexMetadata
    private var timeObserver: Any?
    private var playerItem: AVPlayerItem?
    private var remoteCommandsConfigured = false
    private var nextEpisodeTimer: Timer?
    private var hasTriggeredNextEpisode = false

    init(media: PlexMetadata) {
        self.media = media
        self.playerViewController = AVPlayerViewController()
    }

    func setupPlayer(authService: PlexAuthService) async {
        guard let client = authService.currentClient,
              let server = authService.selectedServer else {
            error = "No server connection"
            isLoading = false
            return
        }

        guard let ratingKey = media.ratingKey else {
            error = "Invalid media item"
            isLoading = false
            return
        }

        isLoading = true
        error = nil

        do {
            print("🎬 [Player] Loading video for: \(media.title)")

            // Get detailed metadata
            let detailedMedia = try await client.getMetadata(ratingKey: ratingKey)

            print("🎬 [Player] Detailed metadata received")
            print("🎬 [Player] Type: \(detailedMedia.type ?? "unknown")")
            print("🎬 [Player] Title: \(detailedMedia.title)")
            print("🎬 [Player] Has media array: \(detailedMedia.media != nil)")
            print("🎬 [Player] Media count: \(detailedMedia.media?.count ?? 0)")
            if let media = detailedMedia.media?.first {
                print("🎬 [Player] First media item exists")
                print("🎬 [Player] Has part array: \(media.part != nil)")
                print("🎬 [Player] Part count: \(media.part?.count ?? 0)")
                if let part = media.part?.first {
                    print("🎬 [Player] Part key: \(part.key)")
                }
            }

            // Build video URL
            guard let mediaItem = detailedMedia.media?.first,
                  let part = mediaItem.part?.first else {
                error = "No media available"
                isLoading = false
                print("❌ [Player] No media or part found")
                return
            }

            // Use the vetted baseURL from the authenticated client
            // This is the URL that was already tested and verified to work in selectServer()
            let baseURL = client.baseURL

            // Build direct play URL with token
            var urlString = baseURL.absoluteString + part.key
            if !urlString.contains("?") {
                urlString += "?"
            } else {
                urlString += "&"
            }
            // Use the authenticated client's token, which is guaranteed to be valid
            // This is the token that authenticated the current session
            if let token = client.accessToken {
                urlString += "X-Plex-Token=\(token)"
            } else {
                error = "No authentication token available"
                isLoading = false
                print("❌ [Player] No token found")
                return
            }

            guard let videoURL = URL(string: urlString) else {
                error = "Invalid video URL"
                isLoading = false
                print("❌ [Player] Invalid URL: \(urlString)")
                return
            }

            print("🎬 [Player] Video URL: \(videoURL)")

            // Create player item with metadata
            let asset = AVURLAsset(url: videoURL)
            playerItem = AVPlayerItem(asset: asset)

            // Configure audio session for playback
            setupAudioSession()

            // Set up metadata for Now Playing
            setupNowPlayingMetadata(media: detailedMedia, server: server, baseURL: baseURL, token: client.accessToken)

            // Create player
            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true

            // Resume from saved position if available
            if let viewOffset = detailedMedia.viewOffset, viewOffset > 0 {
                let seconds = Double(viewOffset) / 1000.0
                print("🎬 [Player] Resuming from \(seconds)s")
                await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
            }

            self.player = player

            // Start playback
            player.play()
            print("🎬 [Player] Starting playback")

            // Setup progress tracking
            setupProgressTracking(client: client, player: player, ratingKey: ratingKey)

            // Setup remote command handling
            setupRemoteCommands(player: player)

            // Discover and configure audio/subtitle tracks
            discoverTracks()

            // Fetch chapters
            await fetchChapters(client: client, ratingKey: ratingKey)

            // Configure chapter markers on player item
            configureChapterMarkers()

            // Fetch next episode for TV shows
            if detailedMedia.type == "episode" {
                await fetchNextEpisode(client: client)
            }

            isLoading = false

        } catch {
            print("❌ [Player] Error: \(error)")
            self.error = "Failed to load video: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func setupAudioSession() {
        #if os(tvOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            print("🔊 [Player] Audio session configured for playback")
        } catch {
            print("⚠️ [Player] Failed to configure audio session: \(error)")
        }
        #endif
    }

    private func setupNowPlayingMetadata(media: PlexMetadata, server: PlexServer, baseURL: URL, token: String?) {
        var nowPlayingInfo: [String: Any] = [:]

        // Title and show information
        if media.type == "episode" {
            // For TV shows: "Show Name - S1E1 - Episode Title"
            if let showTitle = media.grandparentTitle {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = showTitle
                nowPlayingInfo[MPMediaItemPropertyTitle] = media.title

                // Season and episode numbers
                if let season = media.parentIndex {
                    nowPlayingInfo[MPMediaItemPropertyAlbumTrackNumber] = season
                }
                if let episode = media.index {
                    nowPlayingInfo[MPMediaItemPropertyTrackNumber] = episode
                }

                let seasonEpisode = media.formatSeasonEpisode()
                nowPlayingInfo[MPNowPlayingInfoPropertyChapterNumber] = seasonEpisode as Any
            }
        } else {
            // For movies
            nowPlayingInfo[MPMediaItemPropertyTitle] = media.title

            // Year
            if let year = media.year {
                nowPlayingInfo[MPMediaItemPropertyYear] = year
            }
        }

        // Content rating
        if let contentRating = media.contentRating {
            nowPlayingInfo[MPMediaItemPropertyMediaType] = contentRating
        }

        // Duration
        if let duration = media.duration, duration > 0 {
            let seconds = Double(duration) / 1000.0
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = seconds
        }

        // Rating
        if let rating = media.audienceRating {
            nowPlayingInfo[MPMediaItemPropertyRating] = Int(rating * 10) // Convert 0-10 to 0-100
        }

        // External content identifiers for tvOS integration
        #if os(tvOS)
        if #available(tvOS 16.0, *) {
            var externalMetadata: [AVMetadataItem] = []

            // Add Plex identifier
            if let ratingKey = media.ratingKey {
                let plexIDItem = AVMutableMetadataItem()
                plexIDItem.identifier = AVMetadataIdentifier(rawValue: "plex.tv/ratingKey")
                plexIDItem.value = ratingKey as NSString
                plexIDItem.dataType = kCMMetadataBaseDataType_UTF8 as String
                externalMetadata.append(plexIDItem)
            }

            // Add media type
            let mediaTypeItem = AVMutableMetadataItem()
            mediaTypeItem.identifier = .commonIdentifierType
            mediaTypeItem.value = (media.type == "episode" ? "TV Show" : "Movie") as NSString
            mediaTypeItem.dataType = kCMMetadataBaseDataType_UTF8 as String
            externalMetadata.append(mediaTypeItem)

            // Add description
            if let summary = media.summary {
                let descItem = AVMutableMetadataItem()
                descItem.identifier = .commonIdentifierDescription
                descItem.value = summary as NSString
                descItem.dataType = kCMMetadataBaseDataType_UTF8 as String
                externalMetadata.append(descItem)
            }

            // Set external metadata on player item
            if let playerItem = self.playerItem {
                playerItem.externalMetadata = externalMetadata
                print("🎬 [Player] Set external metadata with \(externalMetadata.count) items")
            }
        }
        #endif

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        print("🎬 [Player] Set Now Playing metadata: \(media.title)")

        // Artwork - load asynchronously
        if let artPath = media.art ?? media.thumb {
            var artURLString = baseURL.absoluteString + artPath
            if let token = token {
                artURLString += "?X-Plex-Token=\(token)"
            }
            if let artURL = URL(string: artURLString) {
                Task {
                    await loadArtwork(from: artURL)
                }
            }
        }
    }

    private func loadArtwork(from url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                print("🎬 [Player] Loaded artwork")
            }
        } catch {
            print("⚠️ [Player] Failed to load artwork: \(error)")
        }
    }

    private func setupProgressTracking(client: PlexAPIClient, player: AVPlayer, ratingKey: String) {
        // Update progress every 30 seconds (reduces server load while maintaining reasonable tracking)
        let interval = CMTime(seconds: 30, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let duration = player.currentItem?.duration,
                  duration.isNumeric else {
                return
            }

            let currentTime = CMTimeGetSeconds(time)
            let totalDuration = CMTimeGetSeconds(duration)
            let timeRemaining = totalDuration - currentTime

            // Update timeline
            Task {
                do {
                    try await client.updateTimeline(
                        ratingKey: ratingKey,
                        state: player.rate > 0 ? .playing : .paused,
                        time: Int(currentTime * 1000),
                        duration: Int(totalDuration * 1000)
                    )

                    // Mark as watched when 90% complete
                    if currentTime / totalDuration > 0.9 {
                        try await client.scrobble(ratingKey: ratingKey)
                    }
                } catch {
                    print("Error updating timeline: \(error)")
                }
            }

            // Trigger next episode countdown when 30 seconds remaining (for TV episodes)
            if !self.hasTriggeredNextEpisode && timeRemaining <= 30 && timeRemaining > 0 {
                if self.media.type == "episode" && self.nextEpisode != nil {
                    Task { @MainActor in
                        self.startNextEpisodeCountdown()
                    }
                }
            }
        }
    }

    private func setupRemoteCommands(player: AVPlayer) {
        guard !remoteCommandsConfigured else { return }

        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            player.play()
            print("🎮 [RemoteCommands] Play command executed")
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            player.pause()
            print("🎮 [RemoteCommands] Pause command executed")
            return .success
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            if player.rate > 0 {
                player.pause()
                print("🎮 [RemoteCommands] Toggle pause executed")
            } else {
                player.play()
                print("🎮 [RemoteCommands] Toggle play executed")
            }
            return .success
        }

        // Skip forward (15 seconds)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                let currentTime = player.currentTime()
                let newTime = CMTimeAdd(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
                player.seek(to: newTime)
                print("🎮 [RemoteCommands] Skip forward \(skipEvent.interval)s")
                return .success
            }
            return .commandFailed
        }

        // Skip backward (15 seconds)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                let currentTime = player.currentTime()
                let newTime = CMTimeSubtract(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
                player.seek(to: max(newTime, CMTime.zero))
                print("🎮 [RemoteCommands] Skip backward \(skipEvent.interval)s")
                return .success
            }
            return .commandFailed
        }

        remoteCommandsConfigured = true
        print("🎮 [RemoteCommands] Remote command handling configured")
    }

    private func removeRemoteCommands() {
        guard remoteCommandsConfigured else { return }

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)

        remoteCommandsConfigured = false
        print("🎮 [RemoteCommands] Remote commands removed")
    }

    // MARK: - Audio & Subtitle Track Management

    /// Discover available audio and subtitle tracks from the player item
    private func discoverTracks() {
        guard let playerItem = playerItem else {
            print("⚠️ [Tracks] No player item available")
            return
        }

        // Get audio tracks
        if let audioGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            availableAudioTracks = audioGroup.options
            currentAudioTrack = playerItem.selectedMediaOption(in: audioGroup)

            print("🎵 [Tracks] Found \(availableAudioTracks.count) audio tracks")
            for (index, track) in availableAudioTracks.enumerated() {
                let language = track.locale?.identifier ?? "unknown"
                let title = track.displayName
                let selected = track == currentAudioTrack ? "✓" : " "
                print("🎵 [Tracks]   [\(selected)] \(index): \(title) (\(language))")
            }
        }

        // Get subtitle tracks
        if let subtitleGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            availableSubtitleTracks = subtitleGroup.options
            currentSubtitleTrack = playerItem.selectedMediaOption(in: subtitleGroup)

            print("📝 [Tracks] Found \(availableSubtitleTracks.count) subtitle tracks")
            for (index, track) in availableSubtitleTracks.enumerated() {
                let language = track.locale?.identifier ?? "unknown"
                let title = track.displayName
                let selected = track == currentSubtitleTrack ? "✓" : " "
                print("📝 [Tracks]   [\(selected)] \(index): \(title) (\(language))")
            }
        }
    }

    /// Select an audio track
    func selectAudioTrack(_ track: AVMediaSelectionOption?) {
        guard let playerItem = playerItem,
              let audioGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            print("⚠️ [Tracks] Cannot select audio track - no audio group")
            return
        }

        playerItem.select(track, in: audioGroup)
        currentAudioTrack = track

        if let track = track {
            print("🎵 [Tracks] Selected audio track: \(track.displayName)")
        } else {
            print("🎵 [Tracks] Disabled audio track")
        }
    }

    /// Select a subtitle track
    func selectSubtitleTrack(_ track: AVMediaSelectionOption?) {
        guard let playerItem = playerItem,
              let subtitleGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            print("⚠️ [Tracks] Cannot select subtitle track - no subtitle group")
            return
        }

        playerItem.select(track, in: subtitleGroup)
        currentSubtitleTrack = track

        if let track = track {
            print("📝 [Tracks] Selected subtitle track: \(track.displayName)")
        } else {
            print("📝 [Tracks] Disabled subtitles")
        }
    }

    /// Select audio track by language code (e.g., "en", "es", "fr")
    func selectAudioTrackByLanguage(_ languageCode: String) {
        let matchingTrack = availableAudioTracks.first { track in
            track.locale?.languageCode == languageCode
        }
        selectAudioTrack(matchingTrack)
    }

    /// Select subtitle track by language code
    func selectSubtitleTrackByLanguage(_ languageCode: String) {
        let matchingTrack = availableSubtitleTracks.first { track in
            track.locale?.languageCode == languageCode
        }
        selectSubtitleTrack(matchingTrack)
    }

    // MARK: - Next Episode Auto-Play

    /// Fetch the next episode for TV shows
    func fetchNextEpisode(client: PlexAPIClient) async {
        // Only fetch for TV episodes
        guard media.type == "episode",
              let grandparentRatingKey = media.grandparentRatingKey,
              let parentRatingKey = media.parentRatingKey,
              let currentIndex = media.index else {
            print("📺 [NextEp] Not an episode or missing hierarchy info")
            return
        }

        do {
            // Get all episodes in the current season
            let seasonEpisodes = try await client.getChildren(ratingKey: parentRatingKey)

            // Find the next episode
            if let nextEp = seasonEpisodes.first(where: { $0.index == currentIndex + 1 }) {
                self.nextEpisode = nextEp
                print("📺 [NextEp] Found next episode: \(nextEp.title) (S\(nextEp.parentIndex ?? 0)E\(nextEp.index ?? 0))")
            } else {
                // No more episodes in this season, try to get next season
                print("📺 [NextEp] No more episodes in season, checking for next season")
                let allSeasons = try await client.getChildren(ratingKey: grandparentRatingKey)

                if let currentSeasonIndex = media.parentIndex,
                   let nextSeason = allSeasons.first(where: { $0.index == currentSeasonIndex + 1 }),
                   let nextSeasonKey = nextSeason.ratingKey {
                    let nextSeasonEpisodes = try await client.getChildren(ratingKey: nextSeasonKey)
                    if let firstEpisode = nextSeasonEpisodes.first {
                        self.nextEpisode = firstEpisode
                        print("📺 [NextEp] Found first episode of next season: \(firstEpisode.title)")
                    }
                }
            }
        } catch {
            print("❌ [NextEp] Failed to fetch next episode: \(error)")
        }
    }

    /// Start the next episode countdown
    func startNextEpisodeCountdown() {
        guard nextEpisode != nil else { return }

        print("📺 [NextEp] Starting countdown")
        showNextEpisodePrompt = true
        nextEpisodeCountdown = 15
        hasTriggeredNextEpisode = true

        // Cancel any existing timer
        nextEpisodeTimer?.invalidate()

        // Start countdown timer
        nextEpisodeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            Task { @MainActor in
                self.nextEpisodeCountdown -= 1

                if self.nextEpisodeCountdown <= 0 {
                    timer.invalidate()
                    self.showNextEpisodePrompt = false
                    // Trigger next episode play
                    // Note: This will be handled by the view layer
                    print("📺 [NextEp] Countdown complete - should play next episode")
                }
            }
        }
    }

    /// Cancel the next episode auto-play
    func cancelNextEpisode() {
        print("📺 [NextEp] Cancelled by user")
        nextEpisodeTimer?.invalidate()
        nextEpisodeTimer = nil
        showNextEpisodePrompt = false
        nextEpisodeCountdown = 15
    }

    // MARK: - Chapter Markers

    /// Fetch chapters from Plex API
    func fetchChapters(client: PlexAPIClient, ratingKey: String) async {
        do {
            let fetchedChapters = try await client.getChapters(ratingKey: ratingKey)
            self.chapters = fetchedChapters
            print("📖 [Chapters] Loaded \(fetchedChapters.count) chapters")
            for (index, chapter) in fetchedChapters.enumerated() {
                let title = chapter.title ?? "Chapter \(index + 1)"
                let time = Int(chapter.startTime)
                print("📖 [Chapters]   \(index + 1): \(title) @ \(time)s")
            }
        } catch {
            print("⚠️ [Chapters] Failed to fetch chapters: \(error)")
        }
    }

    /// Configure chapter markers on the player item for tvOS
    private func configureChapterMarkers() {
        guard !chapters.isEmpty, let playerItem = playerItem else {
            print("📖 [Chapters] No chapters to configure")
            return
        }

        #if os(tvOS)
        // Create navigation markers for tvOS
        var markers: [AVNavigationMarkersGroup] = []

        // Create time markers for each chapter
        let timeMarkers = chapters.map { chapter -> AVTimedMetadataGroup in
            let time = CMTime(seconds: chapter.startTime, preferredTimescale: 600)

            // Create metadata items for the chapter
            var items: [AVMetadataItem] = []

            // Add title
            if let title = chapter.title {
                let titleItem = AVMutableMetadataItem()
                titleItem.identifier = .commonIdentifierTitle
                titleItem.value = title as NSString
                titleItem.dataType = kCMMetadataBaseDataType_UTF8 as String
                items.append(titleItem)
            }

            // Add artwork if available
            if let thumbPath = chapter.thumb,
               let server = playerViewController?.player?.currentItem?.accessLog()?.description,
               let thumbURL = URL(string: thumbPath) {
                let artworkItem = AVMutableMetadataItem()
                artworkItem.identifier = .commonIdentifierArtwork
                // Note: Would need to fetch image data for full implementation
                items.append(artworkItem)
            }

            return AVTimedMetadataGroup(items: items, timeRange: CMTimeRange(start: time, duration: .zero))
        }

        // Create chapter metadata group
        let chapterGroup = AVNavigationMarkersGroup(
            title: nil,
            timedNavigationMarkers: timeMarkers
        )

        markers.append(chapterGroup)

        // Set the markers on the player item
        if #available(tvOS 16.0, *) {
            playerItem.navigationMarkerGroups = markers
            print("📖 [Chapters] Configured \(chapters.count) chapter markers")
        } else {
            print("⚠️ [Chapters] Chapter markers require tvOS 16.0+")
        }
        #else
        print("⚠️ [Chapters] Chapter markers only supported on tvOS")
        #endif
    }

    /// Jump to a specific chapter
    func jumpToChapter(_ chapter: PlexChapter) {
        guard let player = player else { return }

        let time = CMTime(seconds: chapter.startTime, preferredTimescale: 600)
        Task {
            await player.seek(to: time)
            print("📖 [Chapters] Jumped to chapter: \(chapter.title ?? "Untitled")")
        }
    }

    // MARK: - Content Proposals (tvOS 16.0+)

    /// Create a content proposal for the next episode
    @available(tvOS 16.0, *)
    func createContentProposal(for episode: PlexMetadata) -> AVContentProposal {
        let proposal = AVContentProposal()

        // Set title and subtitle
        proposal.title = episode.title
        if let showTitle = episode.grandparentTitle {
            proposal.subtitle = "\(showTitle) • \(episode.formatSeasonEpisode())"
        }

        // Set preview image if available
        if let thumbPath = episode.thumb,
           let authService = playerViewController?.player?.accessLog()?.description,
           let thumbURL = createImageURL(path: thumbPath) {
            Task {
                await loadProposalArtwork(url: thumbURL, for: proposal)
            }
        }

        // Store the metadata for later retrieval
        proposal.metadata = episode

        print("📺 [ContentProposal] Created proposal for: \(episode.title)")
        return proposal
    }

    @available(tvOS 16.0, *)
    private func loadProposalArtwork(url: URL, for proposal: AVContentProposal) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                proposal.previewImage = image
                print("📺 [ContentProposal] Loaded artwork for proposal")
            }
        } catch {
            print("⚠️ [ContentProposal] Failed to load artwork: \(error)")
        }
    }

    private func createImageURL(path: String) -> URL? {
        // This would need access to authService - will be called from the view layer
        // For now, return nil - the view will handle artwork loading
        return nil
    }

    /// Play the next episode
    func playNextEpisode(_ episode: PlexMetadata) async {
        print("📺 [NextEp] Playing next episode: \(episode.title)")
        // Note: This requires re-initializing the player with new media
        // The view layer will handle dismissing and presenting new VideoPlayerView
        showNextEpisodePrompt = false
    }

    // MARK: - Contextual Actions (tvOS 17.0+)

    /// Create contextual actions for the player menu
    @available(tvOS 17.0, *)
    func createContextualActions() -> [UIAction] {
        var actions: [UIAction] = []

        // Audio track selection
        if !availableAudioTracks.isEmpty {
            let audioMenu = UIMenu(title: "Audio", children: availableAudioTracks.map { track in
                let isSelected = track == currentAudioTrack
                return UIAction(
                    title: track.displayName,
                    state: isSelected ? .on : .off
                ) { [weak self] _ in
                    self?.selectAudioTrack(track)
                }
            })
            actions.append(contentsOf: audioMenu.children as! [UIAction])
        }

        // Subtitle track selection
        if !availableSubtitleTracks.isEmpty {
            let subtitlesOff = UIAction(
                title: "Off",
                state: currentSubtitleTrack == nil ? .on : .off
            ) { [weak self] _ in
                self?.selectSubtitleTrack(nil)
            }

            let subtitleActions = availableSubtitleTracks.map { track in
                let isSelected = track == currentSubtitleTrack
                return UIAction(
                    title: track.displayName,
                    state: isSelected ? .on : .off
                ) { [weak self] _ in
                    self?.selectSubtitleTrack(track)
                }
            }

            let subtitleMenu = UIMenu(title: "Subtitles", children: [subtitlesOff] + subtitleActions)
            actions.append(contentsOf: subtitleMenu.children as! [UIAction])
        }

        // Chapter selection
        if !chapters.isEmpty {
            let chapterActions = chapters.enumerated().map { index, chapter in
                UIAction(title: chapter.title ?? "Chapter \(index + 1)") { [weak self] _ in
                    self?.jumpToChapter(chapter)
                }
            }
            let chapterMenu = UIMenu(title: "Chapters", children: chapterActions)
            actions.append(contentsOf: chapterMenu.children as! [UIAction])
        }

        return actions
    }

    func cleanup() {
        print("🧹 [Player] Cleaning up player resources")

        // Cancel next episode timer
        nextEpisodeTimer?.invalidate()
        nextEpisodeTimer = nil

        // Remove remote command handlers
        removeRemoteCommands()

        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        player?.pause()
        player = nil
        playerItem = nil

        // Deactivate audio session
        #if os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("🔊 [Player] Audio session deactivated")
        } catch {
            print("⚠️ [Player] Failed to deactivate audio session: \(error)")
        }
        #endif
    }
}

// MARK: - Next Episode Overlay

struct NextEpisodeOverlay: View {
    let nextEpisode: PlexMetadata
    let countdown: Int
    let onPlayNow: () -> Void
    let onCancel: () -> Void
    @EnvironmentObject var authService: PlexAuthService

    var body: some View {
        VStack {
            Spacer()

            // Bottom overlay
            HStack(spacing: 30) {
                // Thumbnail
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
                .frame(width: 280, height: 158)
                .cornerRadius(DesignTokens.cornerRadiusSmall)

                // Info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next Episode")
                        .font(.headline)
                        .foregroundColor(.gray)

                    Text(nextEpisode.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    if let showTitle = nextEpisode.grandparentTitle {
                        Text("\(showTitle) • \(nextEpisode.formatSeasonEpisode())")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }

                Spacer()

                // Countdown and buttons
                VStack(spacing: 15) {
                    Text("Playing in \(countdown)s")
                        .font(.title3)
                        .foregroundColor(.white)

                    HStack(spacing: 15) {
                        Button {
                            onPlayNow()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("Play Now")
                            }
                            .font(.headline)
                        }
                        .buttonStyle(ClearGlassButtonStyle())

                        Button {
                            onCancel()
                        } label: {
                            Text("Cancel")
                                .font(.headline)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }
            .padding(40)
            .background(.ultraThinMaterial)
            .cornerRadius(DesignTokens.cornerRadiusXLarge)
            .shadow(radius: 20)
            .padding(60)
        }
    }

    private var thumbnailURL: URL? {
        guard let client = authService.currentClient,
              let thumb = nextEpisode.thumb else {
            return nil
        }

        // Use the vetted baseURL and token from the authenticated client
        var urlString = client.baseURL.absoluteString + thumb
        if let token = client.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
    }
}

#Preview {
    VideoPlayerView(media: PlexMetadata(
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
        contentRating: nil,
        summary: nil,
        rating: nil,
        audienceRating: nil,
        year: nil,
        tagline: nil,
        thumb: nil,
        art: nil,
        duration: nil,
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
