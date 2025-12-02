//
//  Extensions.swift
//  Beacon tvOS
//
//  Useful extensions and helpers
//

import SwiftUI
import Combine

// MARK: - View Extensions

extension View {
    /// Disables ScrollView clipping on tvOS when the API is available.
    /// Keeps focus-scaled content (like cards) from having their corners cut off.
    @ViewBuilder
    func tvOSScrollClipDisabled() -> some View {
        if #available(tvOS 17.0, *) {
            self.scrollClipDisabled()
        } else {
            self
        }
    }
}

// MARK: - Button Styles

/// Media Card button style for tvOS focus engine
/// Designed for poster/card-based media browsing with Apple's automatic focus behavior
/// The system handles scale, animation, and parallax effects automatically
struct MediaCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .focusable()
    }
}

/// Card button style - Clean Apple TV design
/// Simple, minimal, no fancy effects
struct CardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.3 : 0.18))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}

/// Apple TV-style button - Clean, simple, minimal
/// Matches the latest Apple TV app design without fancy effects
struct ClearGlassButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(Color.white.opacity(isFocused ? 0.3 : 0.18))
            )
            .clipShape(Capsule())
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}

extension ButtonStyle where Self == CardButtonStyle {
    static var card: CardButtonStyle {
        CardButtonStyle()
    }
}

extension ButtonStyle where Self == ClearGlassButtonStyle {
    static var clearGlass: ClearGlassButtonStyle {
        ClearGlassButtonStyle()
    }
}


// MARK: - Responsive Scaling

/// Helper for responsive scaling based on screen size
enum ResponsiveScale {
    /// Base width for 1080p Apple TV (1920px)
    static let baseWidth: CGFloat = 1920

    /// Get scaling factor for current screen
    static func factor(for width: CGFloat) -> CGFloat {
        return width / baseWidth
    }

    /// Scale a value based on screen width
    static func scaled(_ value: CGFloat, for width: CGFloat) -> CGFloat {
        return value * factor(for: width)
    }
}

extension View {
    /// Get the current screen width for responsive scaling
    func withResponsiveScale<Content: View>(@ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        GeometryReader { geometry in
            content(ResponsiveScale.factor(for: geometry.size.width))
        }
    }
}

// MARK: - Design Tokens

/// Apple TV Design System Tokens
/// Centralized constants for consistent UI implementation across tvOS app
enum DesignTokens {
    // MARK: - Corner Radius
    /// Small corner radius (8pt) - For compact elements, small buttons
    static let cornerRadiusSmall: CGFloat = 8

    /// Medium corner radius (12pt) - For standard buttons, controls
    static let cornerRadiusMedium: CGFloat = 12

    /// Large corner radius (14pt) - For cards, panels, primary buttons
    static let cornerRadiusLarge: CGFloat = 14

    /// Extra large corner radius (16pt) - For media cards, containers
    static let cornerRadiusXLarge: CGFloat = 16

    /// Hero corner radius (20pt) - For hero banners, large featured content
    static let cornerRadiusHero: CGFloat = 20

    // MARK: - Material Opacity
    /// Full material opacity (0.95) - Primary cards and containers
    static let materialOpacityFull: Double = 0.95

    /// Button material opacity (0.85) - Interactive elements
    static let materialOpacityButton: Double = 0.85

    /// Hero material opacity (0.30) - Progress indicators on hero content
    static let materialOpacityHero: Double = 0.30

    /// Subtle material opacity (0.15) - Background tints, subtle overlays
    static let materialOpacitySubtle: Double = 0.15

    /// Dimming overlay opacity (0.40) - Dark overlays for contrast
    static let materialOpacityDimming: Double = 0.40

    // MARK: - Spacing Scale
    /// 4pt - Minimum spacing
    static let spacingXXSmall: CGFloat = 4

    /// 8pt - Compact spacing
    static let spacingXSmall: CGFloat = 8

    /// 12pt - Standard small spacing
    static let spacingSmall: CGFloat = 12

    /// 16pt - Medium spacing
    static let spacingMedium: CGFloat = 16

    /// 20pt - Standard large spacing
    static let spacingLarge: CGFloat = 20

    /// 24pt - Extra large spacing
    static let spacingXLarge: CGFloat = 24

    /// 32pt - Section spacing
    static let spacingXXLarge: CGFloat = 32

    /// 40pt - Major section spacing
    static let spacingXXXLarge: CGFloat = 40

    /// 60pt - Hero spacing
    static let spacingHero: CGFloat = 60

    // MARK: - Shadow Presets
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat

        /// Standard unfocused shadow for cards
        static let cardUnfocused = Shadow(
            color: Color.black.opacity(0.35),
            radius: 12,
            x: 0,
            y: 6
        )

        /// Focused shadow for cards with enhanced depth
        static let cardFocused = Shadow(
            color: Color.black.opacity(0.35),
            radius: 25,
            x: 0,
            y: 12
        )

        /// Unfocused shadow for buttons
        static let buttonUnfocused = Shadow(
            color: Color.black.opacity(0.55),
            radius: 15,
            x: 0,
            y: 7
        )

        /// Focused shadow for buttons with maximum depth
        static let buttonFocused = Shadow(
            color: Color.black.opacity(0.55),
            radius: 30,
            x: 0,
            y: 14
        )

        /// Subtle shadow for overlays
        static let overlay = Shadow(
            color: Color.black.opacity(0.25),
            radius: 10,
            x: 0,
            y: 4
        )
    }

    // MARK: - Animation Presets
    struct Animation {
        let response: Double
        let dampingFraction: Double

        /// Standard focus animation (response: 0.35, damping: 0.75)
        static let focus = Animation(response: 0.35, dampingFraction: 0.75)

        /// Press animation (response: 0.2, damping: 0.65)
        static let press = Animation(response: 0.2, dampingFraction: 0.65)

        /// Quick animation for filters (response: 0.2, damping: 0.7)
        static let quick = Animation(response: 0.2, dampingFraction: 0.7)

        /// Smooth transition (response: 0.4, damping: 0.8)
        static let smooth = Animation(response: 0.4, dampingFraction: 0.8)

        /// Create SwiftUI spring animation
        func spring() -> SwiftUI.Animation {
            .spring(response: response, dampingFraction: dampingFraction)
        }
    }

    // MARK: - Focus Scale
    /// Standard focus scale (1.12) - Applied to most interactive elements
    static let focusScale: CGFloat = 1.12

    /// Press scale (0.94) - Applied when button is pressed
    static let pressScale: CGFloat = 0.94

    // MARK: - Border Width
    /// Standard border width for unfocused elements
    static let borderWidthUnfocused: CGFloat = 1.5

    /// Border width for focused elements
    static let borderWidthFocused: CGFloat = 2.5

    /// Thick border for emphasized focus states
    static let borderWidthFocusedThick: CGFloat = 4.0

    // MARK: - Icon Sizes
    /// Small icon size (20pt)
    static let iconSizeSmall: CGFloat = 20

    /// Medium icon size (24pt)
    static let iconSizeMedium: CGFloat = 24

    /// Large icon size (28pt)
    static let iconSizeLarge: CGFloat = 28

    /// Extra large icon size (32pt)
    static let iconSizeXLarge: CGFloat = 32
}

// MARK: - Color Extensions

extension Color {
    // MARK: - Apple TV Color Palette

    // Simple greys for Apple TV style
    static let tvBackground = Color(hex: "#000000")
    static let tvSurface = Color(hex: "#1c1c1e")
    static let tvSecondary = Color(hex: "#2c2c2e")
    static let tvTertiary = Color(hex: "#3a3a3c")

    // Helper to create Color from hex string
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Date Extensions

extension Date {
    func timeAgo() -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: self, to: now)

        if let years = components.year, years > 0 {
            return "\(years) year\(years == 1 ? "" : "s") ago"
        }
        if let months = components.month, months > 0 {
            return "\(months) month\(months == 1 ? "" : "s") ago"
        }
        if let days = components.day, days > 0 {
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
        if let hours = components.hour, hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        if let minutes = components.minute, minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }

        return "Just now"
    }
}

// MARK: - String Extensions

extension String {
    func truncated(to length: Int, addEllipsis: Bool = true) -> String {
        if self.count <= length {
            return self
        }

        let endIndex = self.index(self.startIndex, offsetBy: length)
        let truncated = String(self[..<endIndex])

        return addEllipsis ? truncated + "..." : truncated
    }
}

// MARK: - URLRequest Extensions

extension URLRequest {
    mutating func addPlexHeaders(token: String? = nil) {
        setValue("application/json", forHTTPHeaderField: "Accept")
        setValue("application/json", forHTTPHeaderField: "Content-Type")
        setValue(PlexAPIClient.plexProduct, forHTTPHeaderField: "X-Plex-Product")
        setValue(PlexAPIClient.plexVersion, forHTTPHeaderField: "X-Plex-Version")
        setValue(PlexAPIClient.plexClientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        setValue(PlexAPIClient.plexPlatform, forHTTPHeaderField: "X-Plex-Platform")

        // Get system version for tvOS
        #if os(tvOS)
        setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Plex-Platform-Version")
        setValue("Apple TV", forHTTPHeaderField: "X-Plex-Device-Name")
        #else
        setValue("Unknown", forHTTPHeaderField: "X-Plex-Platform-Version")
        setValue("Unknown Device", forHTTPHeaderField: "X-Plex-Device-Name")
        #endif

        setValue(PlexAPIClient.plexDevice, forHTTPHeaderField: "X-Plex-Device")

        if let token = token {
            setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    }
}
