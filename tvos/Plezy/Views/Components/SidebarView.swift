//
//  SidebarView.swift
//  Beacon tvOS
//
//  Sidebar navigation matching Apple TV app design
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var tabCoordinator: TabCoordinator
    @Binding var isPresented: Bool

    enum FocusedItem: Hashable {
        case search, home, movies, tvShows, settings
    }

    @FocusState private var focusedItem: FocusedItem?

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar card
            VStack(alignment: .leading, spacing: 0) {
                // Top spacing
                Spacer()
                    .frame(height: 80)

                // Navigation items
                VStack(alignment: .leading, spacing: 4) {
                    SidebarMenuItem(
                        title: TabSelection.search.rawValue,
                        isSelected: tabCoordinator.selectedTab == .search,
                        isFocused: focusedItem == .search
                    ) {
                        selectTab(.search)
                    }
                    .focused($focusedItem, equals: .search)

                    SidebarMenuItem(
                        title: TabSelection.home.rawValue,
                        isSelected: tabCoordinator.selectedTab == .home,
                        isFocused: focusedItem == .home
                    ) {
                        selectTab(.home)
                    }
                    .focused($focusedItem, equals: .home)

                    SidebarMenuItem(
                        title: TabSelection.movies.rawValue,
                        isSelected: tabCoordinator.selectedTab == .movies,
                        isFocused: focusedItem == .movies
                    ) {
                        selectTab(.movies)
                    }
                    .focused($focusedItem, equals: .movies)

                    SidebarMenuItem(
                        title: TabSelection.tvShows.rawValue,
                        isSelected: tabCoordinator.selectedTab == .tvShows,
                        isFocused: focusedItem == .tvShows
                    ) {
                        selectTab(.tvShows)
                    }
                    .focused($focusedItem, equals: .tvShows)

                    // Spacer between sections
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 24)

                    SidebarMenuItem(
                        title: TabSelection.settings.rawValue,
                        isSelected: tabCoordinator.selectedTab == .settings,
                        isFocused: focusedItem == .settings
                    ) {
                        selectTab(.settings)
                    }
                    .focused($focusedItem, equals: .settings)
                }
                .padding(.leading, 70)
                .padding(.trailing, 50)

                Spacer()
            }
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(Color(white: 0.14, opacity: 0.98))
                    .shadow(color: Color.black.opacity(0.5), radius: 40, x: 10, y: 0)
            )
            .padding(.leading, 64)
            .padding(.vertical, 80)

            Spacer()
        }
        .onAppear {
            // Default focus to current tab or Home
            switch tabCoordinator.selectedTab {
            case .search: focusedItem = .search
            case .home: focusedItem = .home
            case .movies: focusedItem = .movies
            case .tvShows: focusedItem = .tvShows
            case .settings: focusedItem = .settings
            }
        }
    }

    private func selectTab(_ tab: TabSelection) {
        tabCoordinator.select(tab)
        // Dismiss sidebar after selection
        withAnimation(.easeOut(duration: 0.25)) {
            isPresented = false
        }
    }
}

struct SidebarMenuItem: View {
    let title: String
    let isSelected: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Selection indicator
                if isSelected {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 8, height: 8)
                }

                Text(title)
                    .font(.system(size: 38, weight: isSelected ? .medium : .regular))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? Color.white.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var isPresented = true

        var body: some View {
            ZStack {
                Color.blue
                    .edgesIgnoringSafeArea(.all)

                if isPresented {
                    SidebarView(isPresented: $isPresented)
                        .environmentObject(TabCoordinator.shared)
                }
            }
        }
    }

    return PreviewWrapper()
}
