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
                .blur(radius: isSidebarPresented ? 10 : 0)
                .scaleEffect(isSidebarPresented ? 0.95 : 1.0)
                .animation(.easeOut(duration: 0.3), value: isSidebarPresented)

            // Menu button (top-left corner)
            if !isSidebarPresented {
                MenuButton(action: {
                    withAnimation {
                        isSidebarPresented = true
                    }
                })
                .padding(.top, 60)
                .padding(.leading, 60)
                .zIndex(2)
            }

            // Sidebar overlay
            if isSidebarPresented {
                Color.black.opacity(0.3)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        withAnimation {
                            isSidebarPresented = false
                        }
                    }

                SidebarView(isPresented: $isSidebarPresented)
                    .transition(.move(edge: .leading))
                    .zIndex(3)
            }
        }
        .onPlayPauseCommand {
            // Toggle sidebar with play/pause button when not playing content
            withAnimation {
                isSidebarPresented.toggle()
            }
        }
        .onMoveCommand { direction in
            // Open sidebar when swiping left from content area
            if direction == .left && !isSidebarPresented {
                withAnimation {
                    isSidebarPresented = true
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

// MARK: - Menu Button Component
struct MenuButton: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 24, weight: .medium))

                Text("Menu")
                    .font(.system(size: 28, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isFocused ? 0.2 : 0.1))
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
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
