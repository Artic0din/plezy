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
        ZStack(alignment: .leading) {
            // Main content area
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .opacity(isSidebarPresented ? 0.4 : 1.0)
                .animation(.easeOut(duration: 0.25), value: isSidebarPresented)
                .disabled(isSidebarPresented)

            // Sidebar overlay
            if isSidebarPresented {
                SidebarView(isPresented: $isSidebarPresented)
                    .transition(.move(edge: .leading))
                    .zIndex(10)
            }
        }
        .onMoveCommand { direction in
            // Open sidebar when swiping left, close when swiping right
            if direction == .left && !isSidebarPresented {
                withAnimation(.easeOut(duration: 0.25)) {
                    isSidebarPresented = true
                }
            } else if direction == .right && isSidebarPresented {
                withAnimation(.easeOut(duration: 0.25)) {
                    isSidebarPresented = false
                }
            }
        }
        // Open sidebar by scrolling up past the top edge
        .gesture(
            DragGesture()
                .onEnded { value in
                    // Swipe from left edge to open
                    if value.startLocation.x < 100 && value.translation.width > 200 && !isSidebarPresented {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isSidebarPresented = true
                        }
                    }
                }
        )
        .onAppear {
            print("📱 [MainTabView] MainTabView appeared with sidebar navigation")
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch tabCoordinator.selectedTab {
        case .home:
            HomeView()
                .onAppear {
                    print("📱 [MainTabView] Home view appeared")
                }
        case .movies:
            MoviesLibraryView()
        case .tvShows:
            TVShowsLibraryView()
        case .search:
            SearchView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(PlexAuthService())
        .environmentObject(SettingsService())
        .environmentObject(StorageService())
        .environmentObject(TabCoordinator.shared)
}
