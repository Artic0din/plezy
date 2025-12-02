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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top spacing
            Spacer()
                .frame(height: 100)

            // Navigation items
            VStack(alignment: .leading, spacing: 0) {
                SidebarMenuItem(
                    title: TabSelection.search.rawValue,
                    isSelected: tabCoordinator.selectedTab == .search
                ) {
                    selectTab(.search)
                }

                SidebarMenuItem(
                    title: TabSelection.home.rawValue,
                    isSelected: tabCoordinator.selectedTab == .home
                ) {
                    selectTab(.home)
                }

                SidebarMenuItem(
                    title: TabSelection.movies.rawValue,
                    isSelected: tabCoordinator.selectedTab == .movies
                ) {
                    selectTab(.movies)
                }

                SidebarMenuItem(
                    title: TabSelection.tvShows.rawValue,
                    isSelected: tabCoordinator.selectedTab == .tvShows
                ) {
                    selectTab(.tvShows)
                }

                // Spacer between sections
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 40)

                SidebarMenuItem(
                    title: TabSelection.settings.rawValue,
                    isSelected: tabCoordinator.selectedTab == .settings
                ) {
                    selectTab(.settings)
                }
            }
            .padding(.leading, 90)
            .padding(.trailing, 60)

            Spacer()
        }
        .frame(width: 480)
        .background(
            Color(white: 0.11, opacity: 0.95)
                .edgesIgnoringSafeArea(.all)
        )
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
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 38, weight: isSelected ? .medium : .regular))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isFocused ? Color(white: 0.25) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .focused($isFocused)
        .animation(.easeOut(duration: 0.15), value: isFocused)
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
