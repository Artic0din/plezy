//
//  MediaCardRow.swift
//  Beacon tvOS
//
//  Reusable card row component that displays exactly 4 cards visible at once
//  with explicit width calculation to prevent SwiftUI auto-packing
//

import SwiftUI

// MARK: - Card Row Layout Constants

/// Layout constants for the 4-card row system
/// These values ensure exactly 4 cards are visible with proper spacing for focus scaling
enum CardRowLayout {
    /// Horizontal padding on each side of the screen
    static let horizontalPadding: CGFloat = 80

    /// Spacing between cards - must accommodate focus scale expansion
    /// With 1.07 scale on a ~400px card, each side expands ~14px
    /// 40px spacing leaves ~12px buffer to prevent overlap
    static let cardSpacing: CGFloat = 40

    /// Focus scale effect applied to cards
    static let focusScale: CGFloat = 1.07

    /// Number of cards visible on screen at once
    static let visibleCardCount: CGFloat = 4

    /// Standard tvOS screen width in logical points
    static let screenWidth: CGFloat = 1920

    /// Calculated card width for exactly 4 visible cards
    /// Formula: (screenWidth - totalHorizontalPadding - totalSpacingBetweenCards) / 4
    static var cardWidth: CGFloat {
        let totalPadding = horizontalPadding * 2  // 160
        let totalSpacing = cardSpacing * (visibleCardCount - 1)  // 120 (3 gaps)
        return (screenWidth - totalPadding - totalSpacing) / visibleCardCount  // 410
    }

    /// Card height maintaining 16:9 aspect ratio
    static var cardHeight: CGFloat {
        cardWidth * (9.0 / 16.0)  // ~230.6
    }

    /// Card height for poster-style (2:3 aspect ratio)
    static var posterHeight: CGFloat {
        cardWidth * 1.5  // ~615
    }

    /// Calculate card width from geometry for dynamic layouts
    static func cardWidth(for screenWidth: CGFloat) -> CGFloat {
        let totalPadding = horizontalPadding * 2
        let totalSpacing = cardSpacing * (visibleCardCount - 1)
        return (screenWidth - totalPadding - totalSpacing) / visibleCardCount
    }

    /// Calculate card height from width with 16:9 aspect ratio
    static func cardHeight(for width: CGFloat) -> CGFloat {
        width * (9.0 / 16.0)
    }
}

// MARK: - Media Card Row

/// A horizontal scrolling row that displays exactly 4 cards visible at once
/// Card width is explicitly calculated to fit 4 cards with consistent spacing
struct MediaCardRow<Content: View>: View {
    let items: [PlexMetadata]
    let title: String
    let onItemTap: (PlexMetadata) -> Void
    let cardContent: ((PlexMetadata, CGFloat, CGFloat) -> Content)?

    /// Initialize with default MediaCard rendering
    init(
        items: [PlexMetadata],
        title: String,
        onItemTap: @escaping (PlexMetadata) -> Void
    ) where Content == EmptyView {
        self.items = items
        self.title = title
        self.onItemTap = onItemTap
        self.cardContent = nil
    }

    /// Initialize with custom card content
    init(
        items: [PlexMetadata],
        title: String,
        onItemTap: @escaping (PlexMetadata) -> Void,
        @ViewBuilder cardContent: @escaping (PlexMetadata, CGFloat, CGFloat) -> Content
    ) {
        self.items = items
        self.title = title
        self.onItemTap = onItemTap
        self.cardContent = cardContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section title
            Text(title)
                .font(.system(size: 40, weight: .bold, design: .default))
                .foregroundColor(.white)
                .padding(.horizontal, CardRowLayout.horizontalPadding)
                .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 2)

            // Horizontal scrolling row with explicit card sizing
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CardRowLayout.cardSpacing) {
                    ForEach(items) { item in
                        if let customContent = cardContent {
                            customContent(item, CardRowLayout.cardWidth, CardRowLayout.cardHeight)
                        } else {
                            MediaCard(
                                media: item,
                                config: .custom(
                                    width: CardRowLayout.cardWidth,
                                    height: CardRowLayout.cardHeight,
                                    showProgress: true,
                                    showLabel: .inside,
                                    showLogo: true,
                                    showEpisodeLabelBelow: item.type == "episode"
                                )
                            ) {
                                onItemTap(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, CardRowLayout.horizontalPadding)
            }
            .tvOSScrollClipDisabled()
        }
        .padding(.bottom, 60)
        .focusSection()
    }
}

// MARK: - Continue Watching Row

/// Specialized row for Continue Watching with play action
struct ContinueWatchingRow: View {
    let items: [PlexMetadata]
    let onPlay: (PlexMetadata) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Continue Watching")
                .font(.system(size: 40, weight: .bold, design: .default))
                .foregroundColor(.white)
                .padding(.horizontal, CardRowLayout.horizontalPadding)
                .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 2)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CardRowLayout.cardSpacing) {
                    ForEach(items) { item in
                        MediaCard(
                            media: item,
                            config: .custom(
                                width: CardRowLayout.cardWidth,
                                height: CardRowLayout.cardHeight,
                                showProgress: true,
                                showLabel: .inside,
                                showLogo: true,
                                showEpisodeLabelBelow: item.type == "episode"
                            )
                        ) {
                            onPlay(item)
                        }
                    }
                }
                .padding(.horizontal, CardRowLayout.horizontalPadding)
            }
            .tvOSScrollClipDisabled()
        }
        .padding(.bottom, 60)
        .id("continueWatching")
        .focusSection()
    }
}

// MARK: - Hub Row

/// Row for displaying Plex hub content (Recently Added, library-specific rows, etc.)
struct HubRow: View {
    let hub: PlexHub
    let onItemTap: (PlexMetadata) -> Void

    var body: some View {
        if let items = hub.metadata, !items.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text(hub.title)
                    .font(.system(size: 40, weight: .bold, design: .default))
                    .foregroundColor(.white)
                    .padding(.horizontal, CardRowLayout.horizontalPadding)
                    .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: CardRowLayout.cardSpacing) {
                        ForEach(items) { item in
                            MediaCard(
                                media: item,
                                config: .custom(
                                    width: CardRowLayout.cardWidth,
                                    height: CardRowLayout.cardHeight,
                                    showProgress: true,
                                    showLabel: .inside,
                                    showLogo: true,
                                    showEpisodeLabelBelow: item.type == "episode"
                                )
                            ) {
                                onItemTap(item)
                            }
                        }
                    }
                    .padding(.horizontal, CardRowLayout.horizontalPadding)
                }
                .tvOSScrollClipDisabled()
            }
            .padding(.bottom, 60)
            .focusSection()
        }
    }
}

// MARK: - Geometry-Based Card Row

/// Card row that uses GeometryReader to calculate card width dynamically
/// Use this if you need to support varying screen sizes
struct GeometryMediaCardRow: View {
    let items: [PlexMetadata]
    let title: String
    let onItemTap: (PlexMetadata) -> Void

    var body: some View {
        GeometryReader { geometry in
            let calculatedWidth = CardRowLayout.cardWidth(for: geometry.size.width)
            let calculatedHeight = CardRowLayout.cardHeight(for: calculatedWidth)

            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.system(size: 40, weight: .bold, design: .default))
                    .foregroundColor(.white)
                    .padding(.horizontal, CardRowLayout.horizontalPadding)
                    .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: CardRowLayout.cardSpacing) {
                        ForEach(items) { item in
                            MediaCard(
                                media: item,
                                config: .custom(
                                    width: calculatedWidth,
                                    height: calculatedHeight,
                                    showProgress: true,
                                    showLabel: .inside,
                                    showLogo: true,
                                    showEpisodeLabelBelow: item.type == "episode"
                                )
                            ) {
                                onItemTap(item)
                            }
                        }
                    }
                    .padding(.horizontal, CardRowLayout.horizontalPadding)
                }
                .tvOSScrollClipDisabled()
            }
        }
        .padding(.bottom, 60)
        .focusSection()
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(alignment: .leading, spacing: 40) {
            // Demo showing the calculated card dimensions
            VStack(alignment: .leading, spacing: 8) {
                Text("4-Card Layout Preview")
                    .font(.title)
                    .foregroundColor(.white)
                Text("Card Width: \(Int(CardRowLayout.cardWidth))px")
                    .foregroundColor(.gray)
                Text("Card Height: \(Int(CardRowLayout.cardHeight))px")
                    .foregroundColor(.gray)
                Text("Card Spacing: \(Int(CardRowLayout.cardSpacing))px")
                    .foregroundColor(.gray)
                Text("Focus Scale: \(CardRowLayout.focusScale, specifier: "%.2f")")
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, CardRowLayout.horizontalPadding)

            // Visual representation of 4 cards
            HStack(spacing: CardRowLayout.cardSpacing) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.gray.opacity(0.3))
                        .frame(
                            width: CardRowLayout.cardWidth,
                            height: CardRowLayout.cardHeight
                        )
                        .overlay(
                            Text("Card \(index + 1)")
                                .foregroundColor(.white)
                        )
                }
            }
            .padding(.horizontal, CardRowLayout.horizontalPadding)

            Spacer()
        }
        .padding(.top, 100)
    }
}
