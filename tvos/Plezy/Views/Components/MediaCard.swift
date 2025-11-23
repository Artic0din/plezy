//
//  MediaCard.swift
//  Beacon tvOS
//
//  Unified media card component with tvOS parallax and Liquid Glass styling
//

import SwiftUI
import UIKit

// MARK: - Card Configuration

/// Configuration for MediaCard display options
struct MediaCardConfig {
    /// Card dimensions
    let width: CGFloat
    let height: CGFloat

    /// Display options
    let showProgress: Bool
    let showLabel: LabelDisplay
    let showLogo: Bool
    let showEpisodeLabelBelow: Bool  // Show season/episode info below the card

    /// Label display mode
    enum LabelDisplay {
        case none           // No label
        case inside         // Label overlaid inside card at bottom
        case outside        // Label below card (deprecated, causes alignment issues)
    }

    /// Predefined sizes for common use cases
    /// Larger cards for a more immersive full-screen experience on tvOS
    static let continueWatching = MediaCardConfig(
        width: 500,
        height: 281,
        showProgress: true,
        showLabel: .inside,
        showLogo: true,
        showEpisodeLabelBelow: false
    )

    static let libraryGrid = MediaCardConfig(
        width: 420,
        height: 236,
        showProgress: true,
        showLabel: .inside,
        showLogo: true,
        showEpisodeLabelBelow: false
    )

    static let seasonPoster = MediaCardConfig(
        width: 290,
        height: 435,
        showProgress: false,
        showLabel: .inside,
        showLogo: false,
        showEpisodeLabelBelow: false
    )

    static func custom(
        width: CGFloat,
        height: CGFloat,
        showProgress: Bool = true,
        showLabel: LabelDisplay = .inside,
        showLogo: Bool = true,
        showEpisodeLabelBelow: Bool = false
    ) -> MediaCardConfig {
        MediaCardConfig(
            width: width,
            height: height,
            showProgress: showProgress,
            showLabel: showLabel,
            showLogo: showLogo,
            showEpisodeLabelBelow: showEpisodeLabelBelow
        )
    }
}

// MARK: - tvOS Parallax Card Container

/// UIViewRepresentable that wraps content in a tvOS parallax-enabled container
/// Uses UIInterpolatingMotionEffect for native Apple TV parallax behavior
struct TVParallaxCard<Content: View>: UIViewRepresentable {
    let content: Content
    let cornerRadius: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(
        cornerRadius: CGFloat = DesignTokens.cornerRadiusXLarge,
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.width = width
        self.height = height
    }

    func makeUIView(context: Context) -> UIView {
        let containerView = ParallaxContainerView()
        containerView.cornerRadius = cornerRadius

        // Host the SwiftUI content
        let hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        context.coordinator.hostingController = hostingController

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.hostingController?.rootView = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var hostingController: UIHostingController<Content>?
    }
}

/// Custom UIView with tvOS parallax motion effects
class ParallaxContainerView: UIView {
    var cornerRadius: CGFloat = 16 {
        didSet {
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupParallaxEffect()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupParallaxEffect()
    }

    private func setupParallaxEffect() {
        // Horizontal tilt
        let horizontalMotionEffect = UIInterpolatingMotionEffect(
            keyPath: "layer.transform.rotation.y",
            type: .tiltAlongHorizontalAxis
        )
        horizontalMotionEffect.minimumRelativeValue = NSNumber(value: -0.03)  // ~1.7 degrees
        horizontalMotionEffect.maximumRelativeValue = NSNumber(value: 0.03)

        // Vertical tilt
        let verticalMotionEffect = UIInterpolatingMotionEffect(
            keyPath: "layer.transform.rotation.x",
            type: .tiltAlongVerticalAxis
        )
        verticalMotionEffect.minimumRelativeValue = NSNumber(value: 0.03)
        verticalMotionEffect.maximumRelativeValue = NSNumber(value: -0.03)

        // Combine effects
        let motionEffectGroup = UIMotionEffectGroup()
        motionEffectGroup.motionEffects = [horizontalMotionEffect, verticalMotionEffect]
        addMotionEffect(motionEffectGroup)

        // Enable 3D transforms
        layer.allowsEdgeAntialiasing = true
        clipsToBounds = false
    }

    override var canBecomeFocused: Bool {
        return false  // SwiftUI handles focus
    }
}

// MARK: - Media Card

/// Unified media card component that maintains consistent height and appearance
/// All content (image, progress, labels) fits within a fixed frame to prevent layout shifts
/// Features Liquid Glass styling with tvOS parallax/focus effects
struct MediaCard: View {
    let media: PlexMetadata
    let config: MediaCardConfig
    let action: () -> Void

    @EnvironmentObject var authService: PlexAuthService
    @FocusState private var isFocused: Bool

    init(
        media: PlexMetadata,
        config: MediaCardConfig = .continueWatching,
        action: @escaping () -> Void
    ) {
        self.media = media
        self.config = config
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            cardContent
        }
        // Focus scale with 3D lift effect
        .scaleEffect(isFocused ? CardRowLayout.focusScale : 1.0)
        // Subtle 3D rotation on focus for lift effect
        .rotation3DEffect(
            .degrees(isFocused ? 3 : 0),
            axis: (x: -1, y: 0, z: 0),
            perspective: 0.3
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isFocused)
        .buttonStyle(MediaCardButtonStyle())
        .focused($isFocused)
        .onPlayPauseCommand {
            action()
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to view details")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Card Content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main card with Liquid Glass styling wrapped in parallax container
            TVParallaxCard(
                cornerRadius: DesignTokens.cornerRadiusXLarge,
                width: config.width,
                height: config.height
            ) {
                ZStack(alignment: .bottomLeading) {
                    // Layer 1: Background image
                    CachedAsyncImage(url: artURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Rectangle()
                            .fill(.regularMaterial.opacity(0.3))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: config.width * 0.15))
                                    .foregroundStyle(.tertiary)
                            )
                    }
                    .frame(width: config.width, height: config.height)

                    // Layer 2: Liquid Glass gradient overlay with vibrancy
                    ZStack {
                        // Base gradient for text contrast
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.black.opacity(0.0),
                                Color.black.opacity(0.25),
                                Color.black.opacity(config.showLabel == .inside || config.showProgress ? 0.75 : 0.45)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        // Liquid Glass vibrancy layer
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isFocused ? 0.08 : 0.03),
                                Color.clear,
                                Color.beaconPurple.opacity(isFocused ? 0.12 : 0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .blendMode(.plusLighter)

                        // Liquid Glass edge highlight on focus
                        if isFocused {
                            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusXLarge, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.5),
                                            Color.white.opacity(0.2),
                                            Color.beaconPurple.opacity(0.3)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2.5
                                )
                        }
                    }

                    // Layer 3: Logo/Title overlay (if enabled and inside)
                    if config.showLogo && config.showLabel == .inside {
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer()

                            // Logo or title
                            HStack {
                                if let logoURL = logoURL, let clearLogo = media.clearLogo {
                                    CachedAsyncImage(url: logoURL) { image in
                                        image
                                            .resizable()
                                            .scaledToFit()
                                    } placeholder: {
                                        cardTitleText
                                    }
                                    .frame(
                                        maxWidth: config.width * 0.5,
                                        maxHeight: config.height * 0.25
                                    )
                                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 3)
                                    .id("\(media.id)-\(clearLogo)")
                                } else {
                                    cardTitleText
                                        .frame(maxWidth: config.width * 0.5, alignment: .leading)
                                }
                                Spacer()
                            }
                        }
                        .padding(.leading, config.width * 0.05)
                        .padding(.bottom, config.showProgress ? config.height * 0.12 : config.height * 0.06)
                    }

                    // Layer 4: Progress bar overlay (if enabled)
                    if config.showProgress && media.progress > 0 && media.progress < 0.98 {
                        VStack {
                            Spacer()
                            ZStack(alignment: .leading) {
                                // Background capsule - Liquid Glass effect
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.6)
                                    .frame(width: config.width - 24, height: 6)

                                // Progress capsule - beacon gradient
                                Capsule()
                                    .fill(Color.beaconGradient)
                                    .frame(width: (config.width - 24) * media.progress, height: 6)
                                    .shadow(color: Color.beaconMagenta.opacity(0.7), radius: 6, x: 0, y: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                    }
                }
                .frame(width: config.width, height: config.height)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusXLarge, style: .continuous))
            }
            .frame(width: config.width, height: config.height)
            // Enhanced Liquid Glass shadow with focus state
            .shadow(
                color: isFocused ? Color.beaconPurple.opacity(0.4) : .black.opacity(0.3),
                radius: isFocused ? 50 : 18,
                x: 0,
                y: isFocused ? 25 : 10
            )
            .shadow(
                color: .black.opacity(isFocused ? 0.45 : 0.25),
                radius: isFocused ? 25 : 10,
                x: 0,
                y: isFocused ? 12 : 5
            )

            // Episode label below the card (only for episodes when enabled)
            if config.showEpisodeLabelBelow && media.type == "episode" {
                Text(media.episodeInfo)
                    .font(.system(size: config.width * 0.048, weight: .semibold, design: .default))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: config.width, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            }
        }
    }

    // MARK: - Helper Properties

    private var cardTitleText: some View {
        Text(media.type == "episode" ? (media.grandparentTitle ?? media.title) : media.title)
            .font(.system(size: config.width * 0.053, weight: .bold, design: .default))
            .foregroundColor(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.6), radius: 5, x: 0, y: 2)
    }

    private var accessibilityLabel: String {
        if media.type == "episode", let show = media.grandparentTitle {
            var label = "\(show), \(media.title)"
            label += " \(media.formatSeasonEpisode())"
            if media.progress > 0 {
                let percent = Int(media.progress * 100)
                label += ", \(percent)% watched"
            }
            return label
        } else {
            var label = media.title
            if media.progress > 0 {
                let percent = Int(media.progress * 100)
                label += ", \(percent)% watched"
            }
            return label
        }
    }

    private var artURL: URL? {
        guard let server = authService.selectedServer,
              let baseURL = server.bestBaseURL,
              let art = media.art else {
            return nil
        }

        var urlString = baseURL.absoluteString + art
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
    }

    private var logoURL: URL? {
        guard let server = authService.selectedServer,
              let baseURL = server.bestBaseURL,
              let clearLogo = media.clearLogo else {
            return nil
        }

        if clearLogo.starts(with: "http") {
            return URL(string: clearLogo)
        }

        var urlString = baseURL.absoluteString + clearLogo
        if let token = server.accessToken {
            urlString += "?X-Plex-Token=\(token)"
        }

        return URL(string: urlString)
    }
}

// MARK: - Context Menu Support

/// Actions available in the media card context menu
enum MediaCardContextAction: Identifiable {
    case markWatched
    case markUnwatched
    case removeFromContinueWatching

    var id: String {
        switch self {
        case .markWatched: return "markWatched"
        case .markUnwatched: return "markUnwatched"
        case .removeFromContinueWatching: return "removeFromContinueWatching"
        }
    }

    var title: String {
        switch self {
        case .markWatched: return "Mark as Watched"
        case .markUnwatched: return "Mark as Unwatched"
        case .removeFromContinueWatching: return "Remove from Continue Watching"
        }
    }

    var systemImage: String {
        switch self {
        case .markWatched: return "checkmark.circle"
        case .markUnwatched: return "circle"
        case .removeFromContinueWatching: return "xmark.circle"
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Text("MediaCard Preview")
            .font(.title)
        Text("Use within app with actual PlexMetadata")
            .foregroundColor(.gray)
    }
    .frame(width: 500, height: 300)
}
