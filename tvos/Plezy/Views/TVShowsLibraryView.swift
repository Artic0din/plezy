//
//  TVShowsLibraryView.swift
//  Beacon tvOS
//
//  TV Shows library tab
//

import SwiftUI
import Combine

struct TVShowsLibraryView: View {
    @EnvironmentObject var authService: PlexAuthService
    @EnvironmentObject var tabCoordinator: TabCoordinator
    @State private var libraries: [PlexLibrary] = []
    @State private var isLoading = true
    // Navigation path for hierarchical navigation
    @State private var navigationPath = NavigationPath()

    private let cache = CacheService.shared

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()

                if isLoading {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Loading TV Shows...")
                            .foregroundColor(.gray)
                            .padding(.top)
                    }
                } else if let tvLibrary = libraries.first(where: { $0.mediaType == .show }) {
                    LibraryContentView(library: tvLibrary, navigationPath: $navigationPath)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "tv.badge.questionmark")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)

                        Text("No TV Shows library found")
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationDestination(for: PlexMetadata.self) { media in
                MediaDetailView(media: media)
                    .environmentObject(authService)
            }
        }
        .task {
            await loadLibraries()
        }
    }

    private func loadLibraries() async {
        guard let client = authService.currentClient,
              let serverID = authService.selectedServer?.clientIdentifier else {
            return
        }

        print("📺 [TVShowsLibraryView] Loading fresh libraries (match iOS/macOS)...")
        isLoading = true

        let cacheKey = CacheService.librariesKey(serverID: serverID)

        do {
            let fetchedLibraries = try await client.getLibraries()
            self.libraries = fetchedLibraries

            // Cache the results with 10 minute TTL
            cache.set(cacheKey, value: fetchedLibraries, ttl: 600)

            print("📺 [TVShowsLibraryView] Libraries loaded: \(fetchedLibraries.count)")
        } catch {
            print("Error loading libraries: \(error)")
        }

        isLoading = false
    }
}

#Preview {
    TVShowsLibraryView()
        .environmentObject(PlexAuthService())
}
