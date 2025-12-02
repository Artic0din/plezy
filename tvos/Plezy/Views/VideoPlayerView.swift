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

                // Skip Intro/Credits overlay buttons
                SkipButtonOverlay(playerManager: playerManager)

                // Synopsis overlay (Apple TV style)
                SynopsisOverlay(playerManager: playerManager)
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
                        .buttonStyle(ClearGlassButtonStyle())
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
        // Configure content proposal for next episode (uses system "Up Next" UI)
        if let nextEpisode = playerManager.nextEpisode, playerManager.shouldShowContentProposal {
            configureContentProposal(controller: uiViewController, nextEpisode: nextEpisode, context: context)
        }
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(playerManager: playerManager)
    }

    #if os(tvOS)
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
                subtitleItem.value = "\(showTitle) • S\(season):E\(episode)" as NSString
            } else {
                subtitleItem.value = showTitle as NSString
            }
            metadata.append(subtitleItem)
        }

        proposal.metadata = metadata

        // Set automatic accept delay (15 seconds countdown)
        proposal.automaticAcceptanceInterval = 15

        // Set the proposal on the current player item (not the controller)
        controller.player?.currentItem?.nextContentProposal = proposal

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
            shouldPresent proposal: AVContentProposal
        ) -> Bool {
            // Allow presenting content proposal when we have a next episode
            let shouldPresent = playerManager.nextEpisode != nil
            print("📺 [ContentProposal] Should present: \(shouldPresent)")
            return shouldPresent
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            didAccept proposal: AVContentProposal
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
            didReject proposal: AVContentProposal
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

// MARK: - Skip Button Overlay

/// Overlay view for Skip Intro and Skip Credits buttons
/// Positioned at bottom-right to match Netflix/Apple TV+ style
struct SkipButtonOverlay: View {
    @ObservedObject var playerManager: VideoPlayerManager
    @FocusState private var isSkipIntroFocused: Bool
    @FocusState private var isSkipCreditsFocused: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 16) {
                    // Skip Intro button
                    if playerManager.showSkipIntroButton {
                        Button {
                            playerManager.skipIntro()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                Text("Skip Intro")
                                    .font(.system(size: 24, weight: .semibold))
                            }
                            .foregroundColor(.white)
                        }
                        .buttonStyle(SkipButtonStyle())
                        .focused($isSkipIntroFocused)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }

                    // Skip Credits button
                    if playerManager.showSkipCreditsButton {
                        Button {
                            playerManager.skipCredits()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                Text("Skip Credits")
                                    .font(.system(size: 24, weight: .semibold))
                            }
                            .foregroundColor(.white)
                        }
                        .buttonStyle(SkipButtonStyle())
                        .focused($isSkipCreditsFocused)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.trailing, 80)
                .padding(.bottom, 120)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: playerManager.showSkipIntroButton)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: playerManager.showSkipCreditsButton)
    }
}

/// Button style for Skip Intro/Credits buttons
/// Uses Liquid Glass styling to match the rest of the app
struct SkipButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(
                ZStack {
                    // Dark dimming layer for contrast
                    Capsule()
                        .fill(Color.black.opacity(0.5))

                    // Clear glass material
                    Capsule()
                        .fill(Color.white.opacity(isFocused ? 0.3 : 0.18))
                }
            )
            .shadow(
                color: .black.opacity(isFocused ? 0.6 : 0.4),
                radius: isFocused ? 20 : 10,
                x: 0,
                y: isFocused ? 8 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.05 : 1.0))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Synopsis Overlay

/// Synopsis overlay that appears at playback start (Apple TV style)
struct SynopsisOverlay: View {
    @ObservedObject var playerManager: VideoPlayerManager

    var body: some View {
        if playerManager.showSynopsisOverlay,
           let media = playerManager.detailedMedia,
           let summary = media.summary {
            VStack {
                Spacer()
                    .frame(height: 200)

                HStack {
                    VStack(alignment: .leading, spacing: 16) {
                        // Title
                        if media.type == "episode", let showTitle = media.grandparentTitle {
                            Text(showTitle)
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(.white)

                            if let season = media.parentIndex, let episode = media.index {
                                Text("S\(season):E\(episode) • \(media.title)")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                            }
                        } else {
                            Text(media.title)
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(.white)
                        }

                        // Metadata row
                        HStack(spacing: 12) {
                            if let year = media.year {
                                Text("\(year)")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white.opacity(0.8))
                            }

                            if let rating = media.contentRating {
                                Text(rating)
                                    .font(.system(size: 20))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.2))
                                    .cornerRadius(4)
                            }

                            if let duration = media.duration {
                                let mins = duration / 1000 / 60
                                let hrs = mins / 60
                                let durationStr = hrs > 0 ? "\(hrs)h \(mins % 60)m" : "\(mins)m"
                                Text(durationStr)
                                    .font(.system(size: 20))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }

                        // Synopsis
                        Text(summary)
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(4)
                            .frame(maxWidth: 900, alignment: .leading)
                    }

                    Spacer()
                }
                .padding(.leading, 80)
                .padding(.trailing, 80)

                Spacer()
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.8),
                        Color.black.opacity(0.6),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .transition(.opacity)
        }
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

    // Skip intro state
    @Published var introMarker: PlexMediaMarker?
    @Published var showSkipIntroButton: Bool = false
    @Published var creditsMarker: PlexMediaMarker?
    @Published var showSkipCreditsButton: Bool = false

    // Synopsis overlay state
    @Published var showSynopsisOverlay: Bool = false

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
    private var statusObservation: NSKeyValueObservation?
    private var errorObservation: NSKeyValueObservation?
    private var hasAttemptedFallback = false
    private var currentPartKey: String?
    private var currentRatingKey: String?
    private var currentMediaKey: String?
    private var savedViewOffset: Int?

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

            // Store for potential fallback
            self.currentPartKey = part.key
            self.currentRatingKey = ratingKey
            self.currentMediaKey = String(mediaItem.id)
            self.savedViewOffset = detailedMedia.viewOffset

            // Get playback URL with fallback (Direct Play → Direct Stream → Transcode)
            loadingMessage = "Checking playback compatibility..."

            let playbackDecision = try await client.getPlaybackURL(
                partKey: part.key,
                mediaKey: String(mediaItem.id),
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

            // Observe player item status for playback errors (to trigger fallback)
            setupPlayerItemObservers()

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

            // Show synopsis overlay at start (Apple TV style)
            if detailedMedia.summary != nil {
                showSynopsisOverlay = true
                // Auto-hide after 5 seconds
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.5)) {
                            showSynopsisOverlay = false
                        }
                    }
                }
            }

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

            // Configure skip intro/credits markers (tvOS 16.0+)
            #if os(tvOS)
            if #available(tvOS 16.0, *) {
                await configureSkipMarkers(for: ratingKey, client: client)
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

    /// Observe player item status to detect playback failures and trigger fallback
    private func setupPlayerItemObservers() {
        guard let playerItem = playerItem else { return }

        // Observe status changes
        statusObservation = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    print("✅ [Player] Player item ready to play")
                case .failed:
                    print("❌ [Player] Player item failed: \(item.error?.localizedDescription ?? "unknown error")")
                    await self.handlePlaybackFailure()
                case .unknown:
                    print("⏳ [Player] Player item status unknown")
                @unknown default:
                    break
                }
            }
        }

        // Also observe error property directly
        errorObservation = playerItem.observe(\.error, options: [.new]) { [weak self] item, _ in
            if let error = item.error {
                print("❌ [Player] Player item error: \(error.localizedDescription)")
                Task { @MainActor in
                    await self?.handlePlaybackFailure()
                }
            }
        }

        print("👁️ [Player] Set up player item observers")
    }

    /// Handle playback failure by falling back to transcode
    private func handlePlaybackFailure() async {
        // Only attempt fallback once and only if not already transcoding
        guard !hasAttemptedFallback,
              playbackMethod != .transcode,
              let client = authService?.currentClient,
              let partKey = currentPartKey,
              let ratingKey = currentRatingKey,
              let mediaKey = currentMediaKey else {
            if hasAttemptedFallback {
                print("⚠️ [Player] Already attempted fallback, not retrying")
            }
            return
        }

        hasAttemptedFallback = true
        print("🔄 [Player] Direct play failed, falling back to transcode...")
        loadingMessage = "Switching to transcode..."
        isLoading = true

        // Stop current playback
        player?.pause()
        statusObservation = nil
        errorObservation = nil

        // Stop current transcode session if any
        if let sessionID = currentSessionID {
            await client.stopTranscode(sessionID: sessionID)
        }

        // Build transcode URL directly
        let newSessionID = UUID().uuidString
        guard var components = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: false) else {
            error = "Failed to build transcode URL"
            isLoading = false
            return
        }

        components.path = "/video/:/transcode/universal/start.m3u8"
        var queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "session", value: newSessionID),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "videoCodec", value: "h264,hevc"),
            URLQueryItem(name: "videoResolution", value: "3840x2160"),
            URLQueryItem(name: "maxVideoBitrate", value: "40000"),
            URLQueryItem(name: "audioCodec", value: "aac,ac3,eac3"),
            URLQueryItem(name: "audioBoost", value: "100"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "mediaBufferSize", value: "50000"),
            URLQueryItem(name: "copyts", value: "1"),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPIClient.plexClientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPIClient.plexProduct),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPIClient.plexPlatform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPIClient.plexDevice)
        ]
        if let token = client.accessToken {
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = queryItems

        guard let transcodeURL = components.url else {
            error = "Failed to build transcode URL"
            isLoading = false
            return
        }

        print("🎬 [Player] Fallback transcode URL: \(transcodeURL)")

        // Update session and method
        self.currentSessionID = newSessionID
        self.playbackMethod = .transcode

        // Create new player item
        let asset = AVURLAsset(url: transcodeURL)
        let newPlayerItem = AVPlayerItem(asset: asset)
        self.playerItem = newPlayerItem

        // Set up observers on new item
        setupPlayerItemObservers()

        // Replace current item
        player?.replaceCurrentItem(with: newPlayerItem)

        // Resume from saved position
        if let viewOffset = savedViewOffset, viewOffset > 0 {
            let seconds = Double(viewOffset) / 1000.0
            print("🎬 [Player] Resuming transcode from \(seconds)s")
            await player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }

        // Start playback
        player?.play()
        print("✅ [Player] Fallback transcode started")
        isLoading = false
    }

    /// Helper to create properly formatted metadata items for tvOS transport bar
    private func createMetadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }

    private func setupNowPlayingMetadata(media: PlexMetadata, server: PlexServer, baseURL: URL, token: String?) {
        #if os(tvOS)
        // Build comprehensive metadata for transport bar and auto-generated Info tab (Apple TV style)
        var externalMetadata: [AVMetadataItem] = []

        // TRANSPORT BAR METADATA

        // Title (top line) - Show name for episodes, movie name for movies
        let titleText: String
        if media.type == "episode", let showTitle = media.grandparentTitle {
            titleText = showTitle
            print("🎬 [Metadata] Episode - Title set to show name: '\(titleText)'")
        } else {
            titleText = media.title
            print("🎬 [Metadata] Movie/Other - Title set to media title: '\(titleText)' (type: \(media.type ?? "unknown"))")
        }
        externalMetadata.append(createMetadataItem(identifier: .commonIdentifierTitle, value: titleText))

        // Description (bottom line) - Episode info or movie info
        let descriptionText: String
        if media.type == "episode" {
            if let season = media.parentIndex, let episode = media.index {
                descriptionText = "S\(season):E\(episode) • \(media.title)"
            } else {
                descriptionText = media.title
            }
            print("🎬 [Metadata] Episode - Description: '\(descriptionText)'")
        } else {
            var components: [String] = []
            if let year = media.year {
                components.append("\(year)")
            }
            if let rating = media.contentRating {
                components.append(rating)
            }
            if let duration = media.duration {
                let mins = duration / 1000 / 60
                let hrs = mins / 60
                components.append(hrs > 0 ? "\(hrs)h \(mins % 60)m" : "\(mins)m")
            }
            descriptionText = components.joined(separator: " • ")
            print("🎬 [Metadata] Movie/Other - Description: '\(descriptionText)' (components: \(components.count))")
        }
        externalMetadata.append(createMetadataItem(identifier: .commonIdentifierDescription, value: descriptionText))

        // INFO TAB METADATA (auto-generated by Apple TV)

        // Summary/Synopsis
        if let summary = media.summary {
            externalMetadata.append(createMetadataItem(identifier: .quickTimeMetadataDescription, value: summary))
        }

        // Content Rating
        if let contentRating = media.contentRating {
            externalMetadata.append(createMetadataItem(identifier: .iTunesMetadataContentRating, value: contentRating))
        }

        // Year
        if let year = media.year {
            externalMetadata.append(createMetadataItem(identifier: .commonIdentifierCreationDate, value: "\(year)"))
        }

        // Studio/Network
        if let studio = media.studio {
            externalMetadata.append(createMetadataItem(identifier: .iTunesMetadataPublisher, value: studio))
            externalMetadata.append(createMetadataItem(identifier: .quickTimeMetadataPublisher, value: studio))
        }

        // Genre
        if let genres = media.genre, !genres.isEmpty {
            let genreNames = genres.map { $0.tag }.joined(separator: ", ")
            externalMetadata.append(createMetadataItem(identifier: .quickTimeMetadataGenre, value: genreNames))
        }

        // Director
        if let directors = media.director, !directors.isEmpty {
            let directorNames = directors.map { $0.tag }.joined(separator: ", ")
            externalMetadata.append(createMetadataItem(identifier: .quickTimeMetadataDirector, value: directorNames))
            externalMetadata.append(createMetadataItem(identifier: .iTunesMetadataDirector, value: directorNames))
        }

        // Cast/Actors
        if let roles = media.role, !roles.isEmpty {
            let actorNames = roles.prefix(10).map { $0.tag }.joined(separator: ", ")
            externalMetadata.append(createMetadataItem(identifier: .quickTimeMetadataArtist, value: actorNames))
        }

        // Set metadata on player item
        if let playerItem = self.playerItem {
            playerItem.externalMetadata = externalMetadata
            print("🎬 [Player] Set metadata - Title: '\(titleText)' | Description: '\(descriptionText)'")
            print("🎬 [Player] Total metadata items: \(externalMetadata.count)")
        }
        #endif

        // Now Playing info for Control Center / Lock Screen
        var nowPlayingInfo: [String: Any] = [:]

        if media.type == "episode", let showTitle = media.grandparentTitle {
            nowPlayingInfo[MPMediaItemPropertyTitle] = showTitle
            if let season = media.parentIndex, let episode = media.index {
                nowPlayingInfo[MPMediaItemPropertyArtist] = "S\(season):E\(episode) • \(media.title)"
            }
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = media.title
            if let studio = media.studio {
                nowPlayingInfo[MPMediaItemPropertyArtist] = studio
            }
        }

        if let duration = media.duration, duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000.0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

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
                // Create artwork on main actor, but the artwork's requestHandler closure
                // will be called by MediaPlayer on its own queue. We must ensure the closure
                // is completely nonisolated and only captures the UIImage value.
                await updateNowPlayingArtwork(with: image)
            }
        } catch {
            print("⚠️ [Player] Failed to load artwork: \(error)")
        }
    }

    /// Update Now Playing with artwork - this must be on MainActor
    /// but the MPMediaItemArtwork creation is delegated to a nonisolated helper
    @MainActor
    private func updateNowPlayingArtwork(with image: UIImage) {
        let artwork = Self.makeArtwork(from: image)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        print("🎬 [Player] Loaded artwork")
    }

    /// Creates MPMediaItemArtwork with a non-isolated closure.
    /// This MUST be nonisolated because MPMediaItemArtwork's requestHandler
    /// is called on Apple's MediaPlayer queue, not the main actor.
    /// If the closure were @MainActor-isolated, it would crash with dispatch_assert_queue_fail.
    ///
    /// CRITICAL: This is a static function that captures ONLY the image parameter.
    /// The closure `{ _ in image }` must not reference `self` or any actor-isolated state.
    nonisolated private static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        // Capture image size and the image itself before creating the closure
        let imageSize = image.size
        // The closure is intentionally simple - it just returns the pre-loaded image.
        // This avoids any actor hops when MediaPlayer calls it on its internal queue.
        return MPMediaItemArtwork(boundsSize: imageSize) { _ in image }
    }

    private func setupProgressTracking(client: PlexAPIClient, player: AVPlayer, ratingKey: String) {
        // Use shorter interval for responsive skip button display
        let interval = CMTime(seconds: 1, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let duration = player.currentItem?.duration,
                  duration.isNumeric else {
                return
            }

            let currentTime = CMTimeGetSeconds(time)
            let totalDuration = CMTimeGetSeconds(duration)
            let timeRemaining = totalDuration - currentTime

            // Check if within intro window - show Skip Intro button
            if let intro = self.introMarker {
                let inIntro = currentTime >= intro.start && currentTime < intro.end
                if inIntro != self.showSkipIntroButton {
                    Task { @MainActor in
                        self.showSkipIntroButton = inIntro
                        if inIntro {
                            print("⏩ [SkipIntro] Showing button - in intro window")
                        }
                    }
                }
            }

            // Check if within credits window - show Skip Credits button
            if let credits = self.creditsMarker {
                let inCredits = currentTime >= credits.start && currentTime < credits.end
                if inCredits != self.showSkipCreditsButton {
                    Task { @MainActor in
                        self.showSkipCreditsButton = inCredits
                        if inCredits {
                            print("⏩ [SkipCredits] Showing button - in credits window")
                        }
                    }
                }
            }

            // Update timeline every 30 seconds (not every second)
            let shouldUpdateTimeline = Int(currentTime) % 30 == 0
            if shouldUpdateTimeline {
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

    // MARK: - Skip Intro/Credits

    @available(tvOS 16.0, *)
    private func configureSkipMarkers(for ratingKey: String, client: PlexAPIClient) async {
        do {
            let markers = try await client.getMediaMarkers(ratingKey: ratingKey)

            // Store intro marker for skip button
            if let intro = markers.first(where: { $0.type == "intro" }) {
                self.introMarker = intro
                print("⏩ [SkipIntro] Found intro marker at \(intro.start)s - \(intro.end)s")

                // Also configure as interstitial for timeline display
                let startTime = CMTime(seconds: intro.start, preferredTimescale: 600)
                let endTime = CMTime(seconds: intro.end, preferredTimescale: 600)
                let duration = CMTimeSubtract(endTime, startTime)
                let timeRange = CMTimeRange(start: startTime, duration: duration)

                #if os(tvOS)
                if let playerItem = self.playerItem {
                    let interstitial = AVInterstitialTimeRange(timeRange: timeRange)
                    playerItem.interstitialTimeRanges = [interstitial]
                }
                #endif
            }

            // Store credits marker for skip button
            if let credits = markers.first(where: { $0.type == "credits" }) {
                self.creditsMarker = credits
                print("⏩ [SkipCredits] Found credits marker at \(credits.start)s - \(credits.end)s")
            }
        } catch {
            print("⚠️ [SkipMarkers] Failed to fetch markers: \(error)")
        }
    }

    /// Skip intro - seek to end of intro marker
    func skipIntro() {
        guard let intro = introMarker else { return }
        let seekTime = CMTime(seconds: intro.end, preferredTimescale: 600)
        player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        showSkipIntroButton = false
        print("⏩ [SkipIntro] Skipped to \(intro.end)s")
    }

    /// Skip credits - seek to end of credits marker (triggers content proposal if available)
    func skipCredits() {
        guard let credits = creditsMarker else { return }
        let seekTime = CMTime(seconds: credits.end, preferredTimescale: 600)
        player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        showSkipCreditsButton = false
        print("⏩ [SkipCredits] Skipped to \(credits.end)s")
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
        Image: nil,
        Guid: nil
    ))
    .environmentObject(PlexAuthService())
}
