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
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header spacing
            Spacer()
                .frame(height: 80)

            // Navigation items
            VStack(alignment: .leading, spacing: 12) {
                SidebarMenuItem(
                    title: TabSelection.search.rawValue,
                    icon: TabSelection.search.systemImage,
                    isSelected: tabCoordinator.selectedTab == .search,
                    namespace: namespace
                ) {
                    selectTab(.search)
                }

                SidebarMenuItem(
                    title: TabSelection.home.rawValue,
                    icon: TabSelection.home.systemImage,
                    isSelected: tabCoordinator.selectedTab == .home,
                    namespace: namespace
                ) {
                    selectTab(.home)
                }

                SidebarMenuItem(
                    title: TabSelection.movies.rawValue,
                    icon: TabSelection.movies.systemImage,
                    isSelected: tabCoordinator.selectedTab == .movies,
                    namespace: namespace
                ) {
                    selectTab(.movies)
                }

                SidebarMenuItem(
                    title: TabSelection.tvShows.rawValue,
                    icon: TabSelection.tvShows.systemImage,
                    isSelected: tabCoordinator.selectedTab == .tvShows,
                    namespace: namespace
                ) {
                    selectTab(.tvShows)
                }

                Divider()
                    .background(Color.white.opacity(0.2))
                    .padding(.vertical, 20)

                SidebarMenuItem(
                    title: TabSelection.settings.rawValue,
                    icon: TabSelection.settings.systemImage,
                    isSelected: tabCoordinator.selectedTab == .settings,
                    namespace: namespace
                ) {
                    selectTab(.settings)
                }
            }
            .padding(.leading, 60)

            Spacer()
        }
        .frame(width: 400)
        .background(Color.black.opacity(0.85))
        .edgesIgnoringSafeArea(.all)
    }

    private func selectTab(_ tab: TabSelection) {
        tabCoordinator.select(tab)
        // Dismiss sidebar after selection
        withAnimation(.easeOut(duration: 0.3)) {
            isPresented = false
        }
    }
}

struct SidebarMenuItem: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .frame(width: 40)

                Text(title)
                    .font(.system(size: 32, weight: isSelected ? .semibold : .regular))

                Spacer()
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.7))
            .padding(.horizontal, 30)
            .padding(.vertical, 20)
            .background(
                Group {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.15))
                    } else if isSelected {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.08))
                    }
                }
            )
        }
        .buttonStyle(PlainButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isFocused)
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
