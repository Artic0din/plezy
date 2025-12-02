//
//  MoviesLibraryView.swift
//  Beacon tvOS
//
//  Movies library tab
//

import SwiftUI

struct MoviesLibraryView: View {
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
                        Text("Loading Movies...")
                            .foregroundColor(.gray)
                            .padding(.top)
                    }
                } else if let movieLibrary = libraries.first(where: { $0.mediaType == .movie }) {
                    LibraryContentView(library: movieLibrary, navigationPath: $navigationPath)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "film.badge.questionmark")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)

                        Text("No Movies library found")
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
        .onAppear {
            print("🎬 [MoviesLibraryView] View appeared, isLoading: \(isLoading)")
            if libraries.isEmpty && !isLoading {
                Task {
                    await loadLibraries()
                }
            }
        }
        .task {
            await loadLibraries()
        }
    }

    private func loadLibraries() async {
        print("🎬 [MoviesLibraryView] loadLibraries() called")

        guard let client = authService.currentClient else {
            print("⚠️ [MoviesLibraryView] No current client available")
            isLoading = false
            return
        }

        guard let serverID = authService.selectedServer?.clientIdentifier else {
            print("⚠️ [MoviesLibraryView] No server ID available")
            isLoading = false
            return
        }

        let cacheKey = CacheService.librariesKey(serverID: serverID)

        // Check cache first
        if let cached: [PlexLibrary] = cache.get(cacheKey) {
            print("🎬 [MoviesLibraryView] Using cached libraries (\(cached.count) total)")
            self.libraries = cached
            isLoading = false
            return
        }

        print("🎬 [MoviesLibraryView] Loading fresh libraries...")
        isLoading = true

        do {
            let fetchedLibraries = try await client.getLibraries()
            self.libraries = fetchedLibraries

            // Cache the results with 10 minute TTL
            cache.set(cacheKey, value: fetchedLibraries, ttl: 600)

            print("🎬 [MoviesLibraryView] Libraries loaded: \(fetchedLibraries.count)")
        } catch {
            print("❌ [MoviesLibraryView] Error loading libraries: \(error)")
        }

        isLoading = false
        print("🎬 [MoviesLibraryView] loadLibraries() completed, isLoading: false")
    }
}

#Preview {
    MoviesLibraryView()
        .environmentObject(PlexAuthService())
}
