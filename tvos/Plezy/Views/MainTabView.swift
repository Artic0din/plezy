//
//  MainTabView.swift
//  Beacon tvOS
//
//  Main navigation with sidebar coordinated via TabCoordinator
//

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var authService: PlexAuthService
    // Use injected TabCoordinator from app level (persists across auth state changes)
    @EnvironmentObject var tabCoordinator: TabCoordinator
    @State private var isSidebarPresented = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Main content area
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .opacity(isSidebarPresented ? 0.4 : 1.0)
                .animation(.easeOut(duration: 0.25), value: isSidebarPresented)
                .disabled(isSidebarPresented)

            // Menu button (top-left corner, always visible)
            if !isSidebarPresented {
                MenuButton(action: {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isSidebarPresented = true
                    }
                })
                .padding(.top, 60)
                .padding(.leading, 60)
                .zIndex(5)
            }

            // Sidebar overlay
            if isSidebarPresented {
                SidebarView(isPresented: $isSidebarPresented)
                    .transition(.move(edge: .leading))
                    .zIndex(10)
            }
        }
        .onMoveCommand { direction in
            // Only close sidebar when swiping right (if sidebar is open)
            if direction == .right && isSidebarPresented {
                withAnimation(.easeOut(duration: 0.25)) {
                    isSidebarPresented = false
                }
            }
        }
        .onAppear {
            print("📱 [MainTabView] MainTabView appeared with sidebar navigation")
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch tabCoordinator.selectedTab {
        case .home:
            HomeView()
                .id(TabSelection.home)
                .onAppear {
                    print("📱 [MainTabView] Home view appeared")
                }
        case .movies:
            MoviesLibraryView()
                .id(TabSelection.movies)
        case .tvShows:
            TVShowsLibraryView()
                .id(TabSelection.tvShows)
        case .search:
            SearchView()
                .id(TabSelection.search)
        case .settings:
            SettingsView()
                .id(TabSelection.settings)
        }
    }
}

// MARK: - Menu Button Component
struct MenuButton: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 60, height: 60)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isFocused ? 0.25 : 0.15))
                )
                .scaleEffect(isFocused ? 1.1 : 1.0)
                .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(PlainButtonStyle())
        .focused($isFocused)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}

#Preview {
    MainTabView()
        .environmentObject(PlexAuthService())
        .environmentObject(SettingsService())
        .environmentObject(StorageService())
        .environmentObject(TabCoordinator.shared)
}
