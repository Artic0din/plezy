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
        .onAppear {
            print("📺 [TVShowsLibraryView] View appeared, isLoading: \(isLoading)")
            if libraries.isEmpty && !isLoading {
                Task {
                    await loadLibraries()
                }
            }
        }
        .onChange(of: authService.currentClient) { oldValue, newValue in
            // Reload when client becomes available or changes
            if newValue != nil && libraries.isEmpty {
                print("📺 [TVShowsLibraryView] Client became available, loading libraries...")
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
        print("📺 [TVShowsLibraryView] loadLibraries() called")

        guard let client = authService.currentClient else {
            print("⚠️ [TVShowsLibraryView] No current client available")
            isLoading = false
            return
        }

        guard let serverID = authService.selectedServer?.clientIdentifier else {
            print("⚠️ [TVShowsLibraryView] No server ID available")
            isLoading = false
            return
        }

        let cacheKey = CacheService.librariesKey(serverID: serverID)

        // Check cache first
        if let cached: [PlexLibrary] = cache.get(cacheKey) {
            print("📺 [TVShowsLibraryView] Using cached libraries (\(cached.count) total)")
            self.libraries = cached
            isLoading = false
            return
        }

        print("📺 [TVShowsLibraryView] Loading fresh libraries...")
        isLoading = true

        do {
            let fetchedLibraries = try await client.getLibraries()
            self.libraries = fetchedLibraries

            // Cache the results with 10 minute TTL
            cache.set(cacheKey, value: fetchedLibraries, ttl: 600)

            print("📺 [TVShowsLibraryView] Libraries loaded: \(fetchedLibraries.count)")
        } catch {
            print("❌ [TVShowsLibraryView] Error loading libraries: \(error)")
        }

        isLoading = false
        print("📺 [TVShowsLibraryView] loadLibraries() completed, isLoading: false")
    }
}

#Preview {
    TVShowsLibraryView()
        .environmentObject(PlexAuthService())
}
