//
//  VideoPlayerView.swift
//  Beacon tvOS
//
//  Video player with AVKit featuring:
//  - Playback fallback: Direct Play → Direct Stream → Transcode
//  - tvOS content tabs (Info panel with metadata)
//  - Content proposals for next episode (Up Next)
//  - Skip intro/credits support
//  - Chapter markers
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

                    Text(playerManager.loadingMessage)
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
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            print("🔄 [VideoPlayerView] Scene phase changed from \(oldPhase) to \(newPhase)")
            switch newPhase {
            case .background:
                print("⏸️ [VideoPlayerView] App backgrounded - pausing playback")
                playerManager.player?.pause()
            case .active:
                print("▶️ [VideoPlayerView] App active - resuming playback if it was playing")
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
        controller.transportBarIncludesTitleView = true

        // Set the coordinator as delegate
        controller.delegate = context.coordinator

        print("🎬 [Player] Configured AVPlayerViewController for tvOS")
        #else
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif

        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Update player if it changes
        if uiViewController.player !== playerManager.player {
            uiViewController.player = playerManager.player
        }

        #if os(tvOS)
        // Configure content tabs when metadata is available
        if let detailedMedia = playerManager.detailedMedia {
            configureContentTabs(controller: uiViewController, media: detailedMedia, context: context)
        }

        // Configure content proposal for next episode
        if let nextEpisode = playerManager.nextEpisode, playerManager.shouldShowContentProposal {
            configureContentProposal(controller: uiViewController, nextEpisode: nextEpisode, context: context)
        }
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(playerManager: playerManager)
    }

    #if os(tvOS)
    /// Configure content tabs (Info panel) for tvOS
    private func configureContentTabs(controller: AVPlayerViewController, media: PlexMetadata, context: Context) {
        // Only configure once
        guard controller.customInfoViewControllers.isEmpty else { return }

        // Create info tab with metadata
        let infoVC = createInfoViewController(for: media)
        controller.customInfoViewControllers = [infoVC]

        // Add contextual actions (buttons in transport bar)
        var actions: [UIAction] = []

        // Add "More Like This" action if available
        actions.append(UIAction(
            title: "More Info",
            image: UIImage(systemName: "info.circle")
        ) { _ in
            print("📺 [ContentTabs] More Info tapped")
        })

        controller.contextualActions = actions

        print("📺 [ContentTabs] Configured info tab and contextual actions")
    }

    /// Create the info view controller for content tabs
    private func createInfoViewController(for media: PlexMetadata) -> UIViewController {
        let hostingController = UIHostingController(rootView: PlayerInfoView(media: media))
        hostingController.title = "Info"
        hostingController.tabBarItem = UITabBarItem(
            title: "Info",
            image: UIImage(systemName: "info.circle"),
            selectedImage: UIImage(systemName: "info.circle.fill")
        )
        return hostingController
    }

    /// Configure content proposal for next episode
    private func configureContentProposal(
        controller: AVPlayerViewController,
        nextEpisode: PlexMetadata,
        context: Context
    ) {
        // Create content proposal for the next episode
        let proposal = AVContentProposal(
            contentTimeForTransition: playerManager.contentProposalTime,
            title: nextEpisode.title,
            previewImage: nil // Could load thumbnail here
        )

        // Configure metadata for the proposal
        var metadata: [AVMetadataItem] = []

        // Add show title as subtitle
        if let showTitle = nextEpisode.grandparentTitle {
            let subtitleItem = AVMutableMetadataItem()
            subtitleItem.identifier = .iTunesMetadataTrackSubTitle
            if let season = nextEpisode.parentIndex, let episode = nextEpisode.index {
                subtitleItem.value = "\(showTitle) • S\(season) E\(episode)" as NSString
            } else {
                subtitleItem.value = showTitle as NSString
            }
            metadata.append(subtitleItem)
        }

        proposal.metadata = metadata

        // Set automatic accept delay (15 seconds countdown)
        proposal.automaticAcceptanceInterval = 15

        // Set the proposal on the player view controller
        controller.contentProposalForCurrentTime = proposal

        print("📺 [ContentProposal] Configured proposal for: \(nextEpisode.title)")
    }
    #endif

    @available(tvOS 16.0, *)
    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let playerManager: VideoPlayerManager

        init(playerManager: VideoPlayerManager) {
            self.playerManager = playerManager
            super.init()
        }

        // MARK: - Content Proposal Delegate Methods

        #if os(tvOS)
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            shouldPresentContentProposal proposal: AVContentProposal
        ) -> Bool {
            // Allow presenting content proposal when we have a next episode
            let shouldPresent = playerManager.nextEpisode != nil
            print("📺 [ContentProposal] Should present: \(shouldPresent)")
            return shouldPresent
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            didAcceptContentProposal proposal: AVContentProposal
        ) {
            print("📺 [ContentProposal] User accepted - playing next episode")
            if let nextEpisode = playerManager.nextEpisode {
                Task { @MainActor in
                    await playerManager.playNextEpisode(nextEpisode)
                }
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            didRejectContentProposal proposal: AVContentProposal
        ) {
            print("📺 [ContentProposal] User rejected - staying on current content")
            playerManager.cancelNextEpisode()
        }

        // MARK: - Skip to Next/Previous Episode

        @available(tvOS 16.0, *)
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            skipToNextItemWithCompletion completion: @escaping (Bool) -> Void
        ) {
            if let nextEpisode = playerManager.nextEpisode {
                Task { @MainActor in
                    await playerManager.playNextEpisode(nextEpisode)
                    completion(true)
                }
            } else {
                completion(false)
            }
        }

        @available(tvOS 16.0, *)
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            skipToPreviousItemWithCompletion completion: @escaping (Bool) -> Void
        ) {
            // Could implement previous episode support here
            completion(false)
        }
        #endif
    }
}

// MARK: - Player Info View (Content Tab)

struct PlayerInfoView: View {
    let media: PlexMetadata

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Title
                Text(displayTitle)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                // Episode info for TV shows
                if media.type == "episode" {
                    if let showTitle = media.grandparentTitle {
                        Text(showTitle)
                            .font(.title2)
                            .foregroundColor(.gray)
                    }

                    if let season = media.parentIndex, let episode = media.index {
                        Text("Season \(season), Episode \(episode)")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }

                // Metadata row
                HStack(spacing: 16) {
                    if let year = media.year {
                        Text(String(year))
                            .foregroundColor(.secondary)
                    }

                    if let duration = media.duration {
                        Text(formatDuration(duration))
                            .foregroundColor(.secondary)
                    }

                    if let rating = media.contentRating {
                        Text(rating)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.3))
                            .cornerRadius(4)
                    }

                    if let audienceRating = media.audienceRating {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", audienceRating))
                        }
                    }
                }
                .font(.subheadline)

                // Synopsis
                if let summary = media.summary {
                    Text(summary)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(nil)
                }

                // Cast & Crew
                if let roles = media.role, !roles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cast")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text(roles.prefix(5).map { $0.tag }.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                if let directors = media.director, !directors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Director")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text(directors.map { $0.tag }.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(40)
        }
        .background(Color.black)
    }

    private var displayTitle: String {
        if media.type == "episode" {
            return media.title
        }
        return media.title
    }

    private func formatDuration(_ ms: Int) -> String {
        let mins = ms / 1000 / 60
        let hrs = mins / 60
        return hrs > 0 ? "\(hrs)h \(mins % 60)m" : "\(mins)m"
    }
}

// MARK: - Video Player Manager

@MainActor
class VideoPlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var playerViewController: AVPlayerViewController?
    @Published var isLoading = true
    @Published var loadingMessage = "Loading video..."
    @Published var error: String?
    @Published var availableAudioTracks: [AVMediaSelectionOption] = []
    @Published var availableSubtitleTracks: [AVMediaSelectionOption] = []
    @Published var currentAudioTrack: AVMediaSelectionOption?
    @Published var currentSubtitleTrack: AVMediaSelectionOption?
    @Published var nextEpisode: PlexMetadata?
    @Published var showNextEpisodePrompt: Bool = false
    @Published var nextEpisodeCountdown: Int = 15
    @Published var chapters: [PlexChapter] = []
    @Published var detailedMedia: PlexMetadata?
    @Published var shouldShowContentProposal: Bool = false
    @Published var playbackMethod: PlexAPIClient.PlaybackDecision.PlaybackMethod = .directPlay

    // Time at which to show content proposal (30 seconds before end)
    var contentProposalTime: CMTime {
        guard let duration = player?.currentItem?.duration, duration.isNumeric else {
            return .zero
        }
        let proposalTime = CMTimeSubtract(duration, CMTime(seconds: 30, preferredTimescale: 600))
        return proposalTime
    }

    private let media: PlexMetadata
    private var timeObserver: Any?
    private var playerItem: AVPlayerItem?
    private var remoteCommandsConfigured = false
    private var nextEpisodeTimer: Timer?
    private var hasTriggeredNextEpisode = false
    private var currentSessionID: String?
    private weak var authService: PlexAuthService?

    init(media: PlexMetadata) {
        self.media = media
        self.playerViewController = AVPlayerViewController()
    }

    func setupPlayer(authService: PlexAuthService) async {
        self.authService = authService

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
        loadingMessage = "Loading video..."

        do {
            print("🎬 [Player] Loading video for: \(media.title)")

            // Get detailed metadata
            let detailedMedia = try await client.getMetadata(ratingKey: ratingKey)
            self.detailedMedia = detailedMedia

            print("🎬 [Player] Detailed metadata received")
            print("🎬 [Player] Type: \(detailedMedia.type ?? "unknown")")
            print("🎬 [Player] Title: \(detailedMedia.title)")

            // Build video URL with fallback strategy
            guard let mediaItem = detailedMedia.media?.first,
                  let part = mediaItem.part?.first else {
                error = "No media available"
                isLoading = false
                print("❌ [Player] No media or part found")
                return
            }

            // Get playback URL with fallback (Direct Play → Direct Stream → Transcode)
            loadingMessage = "Checking playback compatibility..."

            let playbackDecision = try await client.getPlaybackURL(
                partKey: part.key,
                mediaKey: mediaItem.id ?? "",
                ratingKey: ratingKey,
                duration: detailedMedia.duration
            )

            self.playbackMethod = playbackDecision.method
            self.currentSessionID = playbackDecision.sessionID

            let methodName: String
            switch playbackDecision.method {
            case .directPlay: methodName = "Direct Play"
            case .directStream: methodName = "Direct Stream"
            case .transcode: methodName = "Transcode"
            }
            loadingMessage = "Starting playback (\(methodName))..."

            print("🎬 [Player] Using \(methodName): \(playbackDecision.url)")

            // Create player item with metadata
            let asset = AVURLAsset(url: playbackDecision.url)
            playerItem = AVPlayerItem(asset: asset)

            // Configure audio session for playback
            setupAudioSession()

            // Set up metadata for Now Playing and tvOS info panel
            setupNowPlayingMetadata(media: detailedMedia, server: server, baseURL: client.baseURL, token: client.accessToken)

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

            // Configure skip intro if available (tvOS 16.0+)
            #if os(tvOS)
            if #available(tvOS 16.0, *) {
                await configureSkipIntro(for: ratingKey, client: client)
            }
            #endif

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

        // Title and subtitle for tvOS display
        if media.type == "episode" {
            if let showTitle = media.grandparentTitle {
                nowPlayingInfo[MPMediaItemPropertyTitle] = showTitle
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = showTitle
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = media.title
        }

        // Duration
        if let duration = media.duration, duration > 0 {
            let seconds = Double(duration) / 1000.0
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = seconds
        }

        // External content identifiers for tvOS integration
        #if os(tvOS)
        if #available(tvOS 16.0, *) {
            var externalMetadata: [AVMetadataItem] = []

            // Set title
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            if media.type == "episode", let showTitle = media.grandparentTitle {
                titleItem.value = showTitle as NSString
            } else {
                titleItem.value = media.title as NSString
            }
            titleItem.dataType = kCMMetadataBaseDataType_UTF8 as String
            externalMetadata.append(titleItem)

            // Set subtitle for TV episodes: "Sx, Ex - Episode Name"
            if media.type == "episode" {
                let subtitleItem = AVMutableMetadataItem()
                subtitleItem.identifier = .iTunesMetadataTrackSubTitle
                if let season = media.parentIndex, let episode = media.index {
                    subtitleItem.value = "S\(season), E\(episode) - \(media.title)" as NSString
                } else {
                    subtitleItem.value = media.title as NSString
                }
                subtitleItem.dataType = kCMMetadataBaseDataType_UTF8 as String
                externalMetadata.append(subtitleItem)
            }

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

            // Enable content proposal when 45 seconds remaining
            if !self.hasTriggeredNextEpisode && timeRemaining <= 45 && timeRemaining > 0 {
                if self.media.type == "episode" && self.nextEpisode != nil {
                    Task { @MainActor in
                        self.shouldShowContentProposal = true
                        self.hasTriggeredNextEpisode = true
                        print("📺 [ContentProposal] Enabled - \(Int(timeRemaining))s remaining")
                    }
                }
            }
        }
    }

    private func setupRemoteCommands(player: AVPlayer) {
        guard !remoteCommandsConfigured else { return }

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            player.play()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            player.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            if player.rate > 0 {
                player.pause()
            } else {
                player.play()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { event in
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                let currentTime = player.currentTime()
                let newTime = CMTimeAdd(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
                player.seek(to: newTime)
                return .success
            }
            return .commandFailed
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { event in
            if let skipEvent = event as? MPSkipIntervalCommandEvent {
                let currentTime = player.currentTime()
                let newTime = CMTimeSubtract(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
                player.seek(to: max(newTime, CMTime.zero))
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
    }

    // MARK: - Audio & Subtitle Track Management

    private func discoverTracks() {
        guard let playerItem = playerItem else { return }

        if let audioGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            availableAudioTracks = audioGroup.options
            currentAudioTrack = playerItem.selectedMediaOption(in: audioGroup)
            print("🎵 [Tracks] Found \(availableAudioTracks.count) audio tracks")
        }

        if let subtitleGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            availableSubtitleTracks = subtitleGroup.options
            currentSubtitleTrack = playerItem.selectedMediaOption(in: subtitleGroup)
            print("📝 [Tracks] Found \(availableSubtitleTracks.count) subtitle tracks")
        }
    }

    func selectAudioTrack(_ track: AVMediaSelectionOption?) {
        guard let playerItem = playerItem,
              let audioGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }
        playerItem.select(track, in: audioGroup)
        currentAudioTrack = track
    }

    func selectSubtitleTrack(_ track: AVMediaSelectionOption?) {
        guard let playerItem = playerItem,
              let subtitleGroup = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        playerItem.select(track, in: subtitleGroup)
        currentSubtitleTrack = track
    }

    // MARK: - Next Episode

    func fetchNextEpisode(client: PlexAPIClient) async {
        guard media.type == "episode",
              let grandparentRatingKey = media.grandparentRatingKey,
              let parentRatingKey = media.parentRatingKey,
              let currentIndex = media.index else { return }

        do {
            let seasonEpisodes = try await client.getChildren(ratingKey: parentRatingKey)

            if let nextEp = seasonEpisodes.first(where: { $0.index == currentIndex + 1 }) {
                self.nextEpisode = nextEp
                print("📺 [NextEp] Found next episode: \(nextEp.title)")
            } else {
                // Try next season
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

    func cancelNextEpisode() {
        nextEpisodeTimer?.invalidate()
        nextEpisodeTimer = nil
        showNextEpisodePrompt = false
        shouldShowContentProposal = false
    }

    func playNextEpisode(_ episode: PlexMetadata) async {
        print("📺 [NextEp] Playing next episode: \(episode.title)")
        showNextEpisodePrompt = false
        shouldShowContentProposal = false
        // Note: The view layer handles dismissing and presenting new VideoPlayerView
    }

    // MARK: - Chapters

    func fetchChapters(client: PlexAPIClient, ratingKey: String) async {
        do {
            let fetchedChapters = try await client.getChapters(ratingKey: ratingKey)
            self.chapters = fetchedChapters
            print("📖 [Chapters] Loaded \(fetchedChapters.count) chapters")
        } catch {
            print("⚠️ [Chapters] Failed to fetch chapters: \(error)")
        }
    }

    private func configureChapterMarkers() {
        guard !chapters.isEmpty, let playerItem = playerItem else { return }

        #if os(tvOS)
        var markers: [AVNavigationMarkersGroup] = []

        let timeMarkers = chapters.map { chapter -> AVTimedMetadataGroup in
            let time = CMTime(seconds: chapter.startTime, preferredTimescale: 600)
            var items: [AVMetadataItem] = []

            if let title = chapter.title {
                let titleItem = AVMutableMetadataItem()
                titleItem.identifier = .commonIdentifierTitle
                titleItem.value = title as NSString
                titleItem.dataType = kCMMetadataBaseDataType_UTF8 as String
                items.append(titleItem)
            }

            return AVTimedMetadataGroup(items: items, timeRange: CMTimeRange(start: time, duration: .zero))
        }

        let chapterGroup = AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: timeMarkers)
        markers.append(chapterGroup)

        if #available(tvOS 16.0, *) {
            playerItem.navigationMarkerGroups = markers
            print("📖 [Chapters] Configured \(chapters.count) chapter markers")
        }
        #endif
    }

    // MARK: - Skip Intro

    @available(tvOS 16.0, *)
    private func configureSkipIntro(for ratingKey: String, client: PlexAPIClient) async {
        do {
            let markers = try await client.getMediaMarkers(ratingKey: ratingKey)

            if let introMarker = markers.first(where: { $0.type == "intro" }) {
                let startTime = CMTime(seconds: introMarker.start, preferredTimescale: 600)
                let endTime = CMTime(seconds: introMarker.end, preferredTimescale: 600)
                let duration = CMTimeSubtract(endTime, startTime)
                let timeRange = CMTimeRange(start: startTime, duration: duration)

                #if os(tvOS)
                if let playerItem = self.playerItem {
                    let interstitial = AVInterstitialTimeRange(timeRange: timeRange)
                    playerItem.interstitialTimeRanges = [interstitial]
                    print("⏩ [SkipIntro] Configured at \(introMarker.start)s - \(introMarker.end)s")
                }
                #endif
            }
        } catch {
            print("⚠️ [SkipIntro] Failed to fetch intro markers: \(error)")
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        print("🧹 [Player] Cleaning up player resources")

        // Stop transcode session if active
        if let sessionID = currentSessionID, playbackMethod == .transcode || playbackMethod == .directStream {
            if let client = authService?.currentClient {
                Task {
                    await client.stopTranscode(sessionID: sessionID)
                }
            }
        }

        nextEpisodeTimer?.invalidate()
        nextEpisodeTimer = nil

        removeRemoteCommands()

        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        player?.pause()
        player = nil
        playerItem = nil

        #if os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ [Player] Failed to deactivate audio session: \(error)")
        }
        #endif
    }
}

// MARK: - Preview

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
