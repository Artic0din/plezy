//
//  PlexAPIClient.swift
//  Beacon tvOS
//
//  Plex API HTTP client
//

import Foundation
import Combine

/// Cache entry wrapper for metadata with timestamp
private class MetadataCacheEntry {
    let metadata: PlexMetadata
    let timestamp: Date

    init(metadata: PlexMetadata, timestamp: Date = Date()) {
        self.metadata = metadata
        self.timestamp = timestamp
    }

    func isValid(ttl: TimeInterval) -> Bool {
        return Date().timeIntervalSince(timestamp) < ttl
    }
}

class PlexAPIClient {
    let baseURL: URL
    let accessToken: String?
    private let session: URLSession

    // In-memory metadata cache to reduce redundant network calls
    // Shared across all instances for efficiency
    private static let metadataCache = NSCache<NSString, MetadataCacheEntry>()
    private static let metadataCacheTTL: TimeInterval = 300  // 5 minutes

    // Plex.tv API constants
    static let plexTVURL = "https://plex.tv"
    static let plexClientIdentifier: String = {
        let key = "PlexClientIdentifier"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        } else {
            let newIdentifier = UUID().uuidString
            UserDefaults.standard.set(newIdentifier, forKey: key)
            return newIdentifier
        }
    }()
    static let plexProduct = "Beacon tvOS"
    static let plexVersion = "1.0.0"
    static let plexPlatform = "tvOS"
    static let plexDevice = "Apple TV"

    // Standard Plex headers
    private var headers: [String: String] {
        var headers = [
            "Accept": "application/json",
            "X-Plex-Product": Self.plexProduct,
            "X-Plex-Version": Self.plexVersion,
            "X-Plex-Client-Identifier": Self.plexClientIdentifier,
            "X-Plex-Platform": Self.plexPlatform,
            "X-Plex-Platform-Version": self.getSystemVersion(),
            "X-Plex-Device": Self.plexDevice,
            "X-Plex-Device-Name": self.getDeviceName()
        ]

        if let token = accessToken {
            headers["X-Plex-Token"] = token
        }

        return headers
    }

    init(baseURL: URL, accessToken: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken

        let configuration = URLSessionConfiguration.default

        // Optimize timeouts for faster response
        configuration.timeoutIntervalForRequest = 15 // Reduced from 30
        configuration.timeoutIntervalForResource = 60 // Reduced from 120

        // Increase max connections per host for better performance (HTTP/2 and HTTP/3 handle multiplexing)
        configuration.httpMaximumConnectionsPerHost = 6 // Allow more concurrent connections

        // Configure aggressive caching
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheURL = cachesDirectory.appendingPathComponent("PlexAPICache")
        let cache = URLCache(
            memoryCapacity: 50 * 1024 * 1024, // 50 MB memory cache
            diskCapacity: 200 * 1024 * 1024,  // 200 MB disk cache
            directory: cacheURL
        )
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad

        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Generic Request Methods

    func request<T: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        retries: Int = 3
    ) async throws -> T {
        // Validate authentication for server endpoints (not plex.tv public endpoints)
        let requiresAuth = !path.hasPrefix("/api/v2/pins") && baseURL.host != "plex.tv"
        if requiresAuth && accessToken == nil {
            print("❌ [API] Unauthorized request to \(path) - no access token")
            throw PlexAPIError.unauthorized
        }

        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            throw PlexAPIError.invalidURL
        }

        var lastError: Error?

        for attempt in 0..<retries {
            if attempt > 0 {
                let delay = min(pow(2.0, Double(attempt)), 16.0) // Cap at 16 seconds
                #if DEBUG
                print("🔄 [API] Retry attempt \(attempt + 1)/\(retries) after \(delay)s delay")
                #endif
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            #if DEBUG
            print("🌐 [API] \(method) \(url) (attempt \(attempt + 1)/\(retries))")
            #endif

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body

            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw PlexAPIError.invalidResponse
                }

                #if DEBUG
                print("🌐 [API] Response: \(httpResponse.statusCode) - \(data.count) bytes")
                #endif

                guard (200...299).contains(httpResponse.statusCode) else {
                    // Provide specific error messages for common HTTP status codes
                    switch httpResponse.statusCode {
                    case 401:
                        throw PlexAPIError.unauthorized
                    case 404:
                        throw PlexAPIError.notFound
                    case 429:
                        throw PlexAPIError.rateLimited
                    case 500...599:
                        throw PlexAPIError.serverError(statusCode: httpResponse.statusCode)
                    default:
                        throw PlexAPIError.httpError(statusCode: httpResponse.statusCode)
                    }
                }

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                decoder.keyDecodingStrategy = .useDefaultKeys

                do {
                    #if DEBUG
                    // Debug: Print first 200 characters of response for inspection
                    if let jsonString = String(data: data, encoding: .utf8) {
                        let preview = String(jsonString.prefix(200))
                        print("🔍 [API] Response preview: \(preview)...")
                    }
                    #endif
                    let result = try decoder.decode(T.self, from: data)
                    return result
                } catch {
                    #if DEBUG
                    print("🔴 [API] Decoding error: \(error)")
                    if let jsonString = String(data: data, encoding: .utf8) {
                        let preview = String(jsonString.prefix(500))
                        print("🔴 [API] Failed JSON preview: \(preview)")
                    }
                    #endif
                    throw PlexAPIError.decodingError(error)
                }
            } catch {
                lastError = error
                #if DEBUG
                print("⚠️ [API] Attempt \(attempt + 1)/\(retries) failed: \(error.localizedDescription)")
                #endif

                // Don't retry on certain errors - they won't succeed on retry
                if let apiError = error as? PlexAPIError {
                    switch apiError {
                    case .unauthorized, .notFound, .decodingError:
                        throw apiError
                    default:
                        break
                    }
                }
            }
        }

        // All retries exhausted, throw the last error
        throw lastError ?? PlexAPIError.serverNotReachable
    }

    /// Request method for endpoints that return empty or no content responses
    /// Used for scrobble, unscrobble, and other action endpoints that just need HTTP success status
    func requestNoContent(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        retries: Int = 3
    ) async throws {
        // Validate authentication for server endpoints (not plex.tv public endpoints)
        let requiresAuth = !path.hasPrefix("/api/v2/pins") && baseURL.host != "plex.tv"
        if requiresAuth && accessToken == nil {
            print("❌ [API] Unauthorized request to \(path) - no access token")
            throw PlexAPIError.unauthorized
        }

        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            throw PlexAPIError.invalidURL
        }

        var lastError: Error?

        for attempt in 0..<retries {
            if attempt > 0 {
                let delay = min(pow(2.0, Double(attempt)), 16.0) // Cap at 16 seconds
                #if DEBUG
                print("🔄 [API] Retry attempt \(attempt + 1)/\(retries) after \(delay)s delay")
                #endif
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            #if DEBUG
            print("🌐 [API] \(method) \(url) (attempt \(attempt + 1)/\(retries))")
            #endif

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body

            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw PlexAPIError.invalidResponse
                }

                #if DEBUG
                print("🌐 [API] Response: \(httpResponse.statusCode) - \(data.count) bytes")
                #endif

                guard (200...299).contains(httpResponse.statusCode) else {
                    // Provide specific error messages for common HTTP status codes
                    switch httpResponse.statusCode {
                    case 401:
                        throw PlexAPIError.unauthorized
                    case 404:
                        throw PlexAPIError.notFound
                    case 429:
                        throw PlexAPIError.rateLimited
                    case 500...599:
                        throw PlexAPIError.serverError(statusCode: httpResponse.statusCode)
                    default:
                        throw PlexAPIError.httpError(statusCode: httpResponse.statusCode)
                    }
                }

                // Success - no need to decode response body
                #if DEBUG
                print("✅ [API] Request successful (no content expected)")
                #endif
                return
            } catch {
                lastError = error
                #if DEBUG
                print("⚠️ [API] Attempt \(attempt + 1)/\(retries) failed: \(error.localizedDescription)")
                #endif

                // Don't retry on certain errors - they won't succeed on retry
                if let apiError = error as? PlexAPIError {
                    switch apiError {
                    case .unauthorized, .notFound:
                        throw apiError
                    default:
                        break
                    }
                }
            }
        }

        // All retries exhausted, throw the last error
        throw lastError ?? PlexAPIError.serverNotReachable
    }

    // MARK: - Library Methods

    func getLibraries() async throws -> [PlexLibrary] {
        let response: PlexResponse<PlexLibrary> = try await request(path: "/library/sections")
        return response.MediaContainer.items
    }

    func getLibraryContent(
        sectionKey: String,
        start: Int = 0,
        size: Int = 50,
        sort: String? = nil,
        unwatched: Bool? = nil
    ) async throws -> [PlexMetadata] {
        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]

        // Add sort parameter if provided
        // Common values: "addedAt:desc", "titleSort:asc", "year:desc", "rating:desc"
        if let sort = sort {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }

        // Add unwatched filter if provided
        if let unwatched = unwatched, unwatched {
            queryItems.append(URLQueryItem(name: "unwatched", value: "1"))
        }

        let response: PlexResponse<PlexMetadata> = try await request(
            path: "/library/sections/\(sectionKey)/all",
            queryItems: queryItems
        )
        return response.MediaContainer.items
    }

    func getMetadata(ratingKey: String) async throws -> PlexMetadata {
        // Check cache first
        let cacheKey = "\(baseURL.absoluteString)_\(ratingKey)" as NSString
        if let entry = Self.metadataCache.object(forKey: cacheKey), entry.isValid(ttl: Self.metadataCacheTTL) {
            #if DEBUG
            print("📡 [API] getMetadata cache HIT for ratingKey: \(ratingKey)")
            #endif
            return entry.metadata
        }

        // Include all necessary data for playback and metadata
        // Based on official Plex API docs: https://plexapi.dev/api-reference/library/get-metadata-by-ratingkey
        let queryItems = [
            URLQueryItem(name: "includeChapters", value: "1"),
            URLQueryItem(name: "includeExtras", value: "0"),
            URLQueryItem(name: "includeImages", value: "1"),
            URLQueryItem(name: "includeGuids", value: "1")  // Include TMDB/IMDB/TVDB IDs
        ]
        #if DEBUG
        print("📡 [API] getMetadata for ratingKey: \(ratingKey)")
        #endif
        let response: PlexResponse<PlexMetadata> = try await request(
            path: "/library/metadata/\(ratingKey)",
            queryItems: queryItems
        )
        #if DEBUG
        print("📡 [API] Metadata response - items count: \(response.MediaContainer.items.count)")
        #endif
        guard let metadata = response.MediaContainer.items.first else {
            throw PlexAPIError.noData
        }
        #if DEBUG
        print("📡 [API] First metadata item - type: \(metadata.type ?? "unknown"), title: \(metadata.title)")
        print("📡 [API] Metadata has media array: \(metadata.media != nil), count: \(metadata.media?.count ?? 0)")
        #endif

        // Cache the result
        let entry = MetadataCacheEntry(metadata: metadata)
        Self.metadataCache.setObject(entry, forKey: cacheKey)

        return metadata
    }

    func getChildren(ratingKey: String) async throws -> [PlexMetadata] {
        let response: PlexResponse<PlexMetadata> = try await request(path: "/library/metadata/\(ratingKey)/children")
        return response.MediaContainer.items
    }

    func getExtras(ratingKey: String) async throws -> [PlexMetadata] {
        let response: PlexResponse<PlexMetadata> = try await request(path: "/library/metadata/\(ratingKey)/extras")
        return response.MediaContainer.items
    }

    func getOnDeck() async throws -> [PlexMetadata] {
        #if DEBUG
        print("📚 [API] Requesting OnDeck from /library/onDeck")
        #endif
        let queryItems = [
            URLQueryItem(name: "includeImages", value: "1"),
            URLQueryItem(name: "includeExtras", value: "1"),
            URLQueryItem(name: "includeCollections", value: "1")
        ]
        let response: PlexResponse<PlexMetadata> = try await request(
            path: "/library/onDeck",
            queryItems: queryItems
        )
        let container = response.MediaContainer
        #if DEBUG
        print("📚 [API] OnDeck response - size: \(container.size), items: \(container.items.count)")
        #endif

        // Enrich episodes with show logos using parallel fetching
        // The onDeck endpoint returns episode metadata, but clearLogos belong to the show (grandparent) level.
        var enrichedItems = container.items

        // Collect unique keys that need fetching (episodes by grandparentRatingKey, movies by ratingKey)
        var showKeysToFetch: Set<String> = []
        var movieKeysToFetch: Set<String> = []

        for item in enrichedItems {
            if item.type == "episode" && item.clearLogo == nil, let grandparentKey = item.grandparentRatingKey {
                showKeysToFetch.insert(grandparentKey)
            } else if item.type == "movie" && item.clearLogo == nil, let ratingKey = item.ratingKey {
                movieKeysToFetch.insert(ratingKey)
            }
        }

        // Fetch all show/movie metadata in parallel using TaskGroup
        var logoCache: [String: String?] = [:]

        // Helper to extract clearLogo from metadata (avoids actor isolation issues in task group)
        func extractClearLogo(from metadata: PlexMetadata) -> String? {
            metadata.Image?.first(where: { $0.type == "clearLogo" })?.url
        }

        await withTaskGroup(of: (String, String?).self) { group in
            // Add tasks for shows
            for showKey in showKeysToFetch {
                group.addTask {
                    do {
                        let metadata = try await self.getMetadata(ratingKey: showKey)
                        // Extract logo inline to avoid actor isolation issues with computed property
                        let logo = metadata.Image?.first(where: { $0.type == "clearLogo" })?.url
                        return (showKey, logo)
                    } catch {
                        return (showKey, nil)
                    }
                }
            }

            // Add tasks for movies
            for movieKey in movieKeysToFetch {
                group.addTask {
                    do {
                        let metadata = try await self.getMetadata(ratingKey: movieKey)
                        // Extract logo inline to avoid actor isolation issues with computed property
                        let logo = metadata.Image?.first(where: { $0.type == "clearLogo" })?.url
                        return (movieKey, logo)
                    } catch {
                        return (movieKey, nil)
                    }
                }
            }

            // Collect results
            for await (key, logo) in group {
                logoCache[key] = logo
            }
        }

        // Apply logos to items
        for (index, item) in enrichedItems.enumerated() {
            if item.type == "episode" && item.clearLogo == nil, let grandparentKey = item.grandparentRatingKey {
                if let logo = logoCache[grandparentKey] ?? nil {
                    var updatedItem = item
                    let logoImage = PlexImage(type: "clearLogo", url: logo)
                    updatedItem.Image = (item.Image ?? []) + [logoImage]
                    enrichedItems[index] = updatedItem
                }
            } else if item.type == "movie" && item.clearLogo == nil, let ratingKey = item.ratingKey {
                if let logo = logoCache[ratingKey] ?? nil {
                    var updatedItem = item
                    let logoImage = PlexImage(type: "clearLogo", url: logo)
                    updatedItem.Image = (item.Image ?? []) + [logoImage]
                    enrichedItems[index] = updatedItem
                }
            }
        }

        #if DEBUG
        print("📚 [API] Enrichment complete: \(enrichedItems.count) items, \(showKeysToFetch.count) shows + \(movieKeysToFetch.count) movies fetched in parallel")
        #endif

        return enrichedItems
    }

    func getRecentlyAdded(sectionKey: String? = nil) async throws -> [PlexMetadata] {
        let path = sectionKey != nil ? "/library/sections/\(sectionKey!)/recentlyAdded" : "/library/recentlyAdded"
        let response: PlexResponse<PlexMetadata> = try await request(path: path)
        return response.MediaContainer.items
    }

    // MARK: - Hub Methods (Content Discovery)

    func getHubs(sectionKey: String? = nil) async throws -> [PlexHub] {
        let path = sectionKey != nil ? "/hubs/sections/\(sectionKey!)" : "/hubs"
        print("📚 [API] Requesting Hubs from \(path)")

        // Include metadata and images in the response
        let queryItems = [
            URLQueryItem(name: "includeImages", value: "1"),
            URLQueryItem(name: "count", value: "20")
        ]

        let response: PlexResponse<PlexMetadata> = try await request(path: path, queryItems: queryItems)
        let container = response.MediaContainer
        let hubs = container.hub ?? []

        print("📚 [API] Hubs response - size: \(container.size), hubs: \(hubs.count)")
        for hub in hubs {
            let metadataCount = hub.metadata?.count ?? 0
            print("📚 [API]   Hub: \(hub.title) - metadata count: \(metadataCount)")
        }

        return hubs
    }

    func getHubContent(hubKey: String) async throws -> [PlexMetadata] {
        let response: PlexResponse<PlexMetadata> = try await request(path: hubKey)
        return response.MediaContainer.items
    }

    // MARK: - Search

    func search(query: String, sectionKey: String? = nil) async throws -> [PlexMetadata] {
        var queryItems = [
            URLQueryItem(name: "query", value: query)
        ]
        if let sectionKey = sectionKey {
            queryItems.append(URLQueryItem(name: "sectionId", value: sectionKey))
        }
        let response: PlexResponse<PlexMetadata> = try await request(
            path: "/hubs/search",
            queryItems: queryItems
        )

        // The /hubs/search endpoint returns Hub objects with nested metadata
        // Extract metadata from each hub and filter for movies and shows only (no episodes)
        // Deduplicate by ratingKey since same items can appear in multiple hubs
        var results: [PlexMetadata] = []
        var seenRatingKeys = Set<String>()
        let validTypes = Set(["movie", "show"])

        if let hubs = response.MediaContainer.hub {
            for hub in hubs {
                // Only include hubs with valid media types
                if validTypes.contains(hub.type), let metadata = hub.metadata {
                    for item in metadata {
                        if let ratingKey = item.ratingKey, !seenRatingKeys.contains(ratingKey) {
                            seenRatingKeys.insert(ratingKey)
                            results.append(item)
                        }
                    }
                }
            }
        }

        return results
    }

    // MARK: - Playback & Progress

    func getMediaInfo(ratingKey: String) async throws -> PlexMetadata {
        try await getMetadata(ratingKey: ratingKey)
    }

    func updateTimeline(ratingKey: String, state: PlaybackState, time: Int, duration: Int) async throws {
        let queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: "\(time)"),
            URLQueryItem(name: "duration", value: "\(duration)")
        ]
        try await requestNoContent(
            path: "/:/timeline",
            queryItems: queryItems
        )
    }

    func scrobble(ratingKey: String) async throws {
        let queryItems = [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: ratingKey)
        ]
        try await requestNoContent(
            path: "/:/scrobble",
            queryItems: queryItems
        )
    }

    func unscrobble(ratingKey: String) async throws {
        let queryItems = [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: ratingKey)
        ]
        try await requestNoContent(
            path: "/:/unscrobble",
            queryItems: queryItems
        )
    }

    /// Mark an item as watched (scrobble)
    /// This marks the entire movie/episode as watched
    func markAsWatched(ratingKey: String) async throws {
        try await scrobble(ratingKey: ratingKey)
        // Invalidate cache for this item
        let cacheKey = "\(baseURL.absoluteString)_\(ratingKey)" as NSString
        Self.metadataCache.removeObject(forKey: cacheKey)
        print("✅ [API] Marked \(ratingKey) as watched")
    }

    /// Mark an item as unwatched (unscrobble)
    /// This removes watch status from the movie/episode
    func markAsUnwatched(ratingKey: String) async throws {
        try await unscrobble(ratingKey: ratingKey)
        // Invalidate cache for this item
        let cacheKey = "\(baseURL.absoluteString)_\(ratingKey)" as NSString
        Self.metadataCache.removeObject(forKey: cacheKey)
        print("✅ [API] Marked \(ratingKey) as unwatched")
    }

    /// Remove an item from Continue Watching by clearing its progress
    /// This sets viewOffset to 0 without marking as watched
    func removeFromContinueWatching(ratingKey: String) async throws {
        // Clear the playback position by setting viewOffset to 0
        // This removes it from On Deck without marking it watched
        let queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "state", value: "stopped"),
            URLQueryItem(name: "time", value: "0"),
            URLQueryItem(name: "duration", value: "0")
        ]
        try await requestNoContent(
            path: "/:/timeline",
            queryItems: queryItems
        )
        // Invalidate cache for this item
        let cacheKey = "\(baseURL.absoluteString)_\(ratingKey)" as NSString
        Self.metadataCache.removeObject(forKey: cacheKey)
        print("✅ [API] Removed \(ratingKey) from Continue Watching")
    }

    // MARK: - Chapters

    func getChapters(ratingKey: String) async throws -> [PlexChapter] {
        struct ChapterContainer: Codable {
            let chapters: [PlexChapter]?
        }
        let container: ChapterContainer = try await request(path: "/library/metadata/\(ratingKey)/chapters")
        return container.chapters ?? []
    }

    // MARK: - Media Markers (Skip Intro, Credits, etc.)

    func getMediaMarkers(ratingKey: String) async throws -> [PlexMediaMarker] {
        struct MarkerResponse: Codable {
            let MediaContainer: MarkerContainer

            struct MarkerContainer: Codable {
                let Marker: [PlexMediaMarker]?
            }
        }

        let response: MarkerResponse = try await request(path: "/library/metadata/\(ratingKey)")
        return response.MediaContainer.Marker ?? []
    }

    enum PlaybackState: String {
        case playing
        case paused
        case stopped
    }

    // MARK: - Playback Decision & Transcoding

    /// Playback decision result containing URL and method
    struct PlaybackDecision {
        enum PlaybackMethod {
            case directPlay
            case directStream
            case transcode
        }

        let url: URL
        let method: PlaybackMethod
        let sessionID: String?
    }

    /// Get the best playback URL for a media item with fallback strategy
    /// Order: Direct Play → Direct Stream → Transcode
    func getPlaybackURL(
        partKey: String,
        mediaKey: String,
        ratingKey: String,
        duration: Int? = nil
    ) async throws -> PlaybackDecision {
        // Generate a unique session ID for this playback
        let sessionID = UUID().uuidString
        print("🎬 [Playback] Starting playback decision for partKey: \(partKey)")

        // Step 1: Try Direct Play first
        if let directPlayURL = buildDirectPlayURL(partKey: partKey) {
            print("🎬 [Playback] Checking Direct Play: \(directPlayURL)")
            if await canPlayDirectly(url: directPlayURL) {
                print("✅ [Playback] Direct Play available")
                return PlaybackDecision(url: directPlayURL, method: .directPlay, sessionID: sessionID)
            }
            print("⚠️ [Playback] Direct Play check failed, trying Direct Stream...")
        } else {
            print("⚠️ [Playback] Could not build Direct Play URL")
        }

        // Step 2: Try Direct Stream (container remux without transcoding)
        if let directStreamURL = buildDirectStreamURL(partKey: partKey, sessionID: sessionID) {
            print("🎬 [Playback] Checking Direct Stream: \(directStreamURL)")
            if await canPlayDirectly(url: directStreamURL) {
                print("✅ [Playback] Direct Stream available")
                return PlaybackDecision(url: directStreamURL, method: .directStream, sessionID: sessionID)
            }
            print("⚠️ [Playback] Direct Stream check failed")
        } else {
            print("⚠️ [Playback] Could not build Direct Stream URL")
        }

        // Step 3: Fall back to Transcode (always works)
        print("🎬 [Playback] Falling back to Transcode...")
        guard let transcodeURL = buildTranscodeURL(
            partKey: partKey,
            mediaKey: mediaKey,
            ratingKey: ratingKey,
            sessionID: sessionID,
            duration: duration
        ) else {
            // Last resort: return direct play URL even if HEAD check failed
            if let directPlayURL = buildDirectPlayURL(partKey: partKey) {
                print("⚠️ [Playback] Transcode URL failed, using Direct Play as fallback")
                return PlaybackDecision(url: directPlayURL, method: .directPlay, sessionID: sessionID)
            }
            throw PlexAPIError.invalidURL
        }
        print("✅ [Playback] Using Transcode URL: \(transcodeURL)")
        return PlaybackDecision(url: transcodeURL, method: .transcode, sessionID: sessionID)
    }

    /// Build direct play URL (original file)
    private func buildDirectPlayURL(partKey: String) -> URL? {
        var urlString = baseURL.absoluteString + partKey
        if !urlString.contains("?") {
            urlString += "?"
        } else {
            urlString += "&"
        }
        if let token = accessToken {
            urlString += "X-Plex-Token=\(token)"
        }
        return URL(string: urlString)
    }

    /// Build direct stream URL (remuxed container, no transcoding)
    private func buildDirectStreamURL(partKey: String, sessionID: String) -> URL? {
        // Direct stream uses /video/:/transcode/universal/start.m3u8 with directStream=1
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/video/:/transcode/universal/start.m3u8"

        var queryItems = [
            URLQueryItem(name: "path", value: partKey),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "copyts", value: "1"),
            URLQueryItem(name: "mediaBufferSize", value: "50000"),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.plexClientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: Self.plexProduct),
            URLQueryItem(name: "X-Plex-Platform", value: Self.plexPlatform)
        ]

        if let token = accessToken {
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    /// Build transcode URL (full transcoding)
    private func buildTranscodeURL(
        partKey: String,
        mediaKey: String,
        ratingKey: String,
        sessionID: String,
        duration: Int?
    ) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/video/:/transcode/universal/start.m3u8"

        // Apple TV supports H.264/HEVC up to 4K, AAC/AC3/EAC3 audio
        var queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            // Video settings - prefer HEVC for better quality/bandwidth
            URLQueryItem(name: "videoCodec", value: "h264,hevc"),
            URLQueryItem(name: "videoResolution", value: "3840x2160"),
            URLQueryItem(name: "maxVideoBitrate", value: "40000"),
            // Audio settings - Apple TV supports these codecs
            URLQueryItem(name: "audioCodec", value: "aac,ac3,eac3"),
            URLQueryItem(name: "audioBoost", value: "100"),
            // Subtitles
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "subtitles", value: "auto"),
            // Buffer settings
            URLQueryItem(name: "mediaBufferSize", value: "50000"),
            URLQueryItem(name: "copyts", value: "1"),
            URLQueryItem(name: "hasMDE", value: "1"),
            // Client identification
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.plexClientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: Self.plexProduct),
            URLQueryItem(name: "X-Plex-Platform", value: Self.plexPlatform),
            URLQueryItem(name: "X-Plex-Device", value: Self.plexDevice)
        ]

        if let token = accessToken {
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }

        components.queryItems = queryItems
        return components.url
    }

    /// Check if a URL can be played directly (HEAD request to verify accessibility)
    private func canPlayDirectly(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let success = (200...299).contains(httpResponse.statusCode)
                print("🎬 [Playback] HEAD check for \(url.path): \(httpResponse.statusCode) - \(success ? "OK" : "FAILED")")
                return success
            }
            return false
        } catch {
            print("🎬 [Playback] HEAD check failed for \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Stop a transcode session
    func stopTranscode(sessionID: String) async {
        let queryItems = [
            URLQueryItem(name: "session", value: sessionID)
        ]

        do {
            let _: PlexMediaContainer<PlexMetadata> = try await request(
                path: "/video/:/transcode/universal/stop",
                queryItems: queryItems
            )
            print("🎬 [Playback] Stopped transcode session: \(sessionID)")
        } catch {
            print("⚠️ [Playback] Failed to stop transcode session: \(error)")
        }
    }
}

// MARK: - Plex.tv API Client

extension PlexAPIClient {
    /// Safe URL for plex.tv - validated at compile time via static let
    private static let plexTVBaseURL: URL = {
        guard let url = URL(string: plexTVURL) else {
            // This should never happen since plexTVURL is a constant valid URL
            // Using fatalError here instead of force unwrap provides better crash diagnostics
            fatalError("Invalid Plex.tv URL constant: \(plexTVURL)")
        }
        return url
    }()

    static func createPlexTVClient(token: String? = nil) -> PlexAPIClient {
        PlexAPIClient(baseURL: plexTVBaseURL, accessToken: token)
    }

    // MARK: - PIN Authentication

    func createPin() async throws -> PlexPin {
        struct PinResponse: Decodable {
            let id: Int
            let code: String
            let qr: String?  // QR code image URL from Plex
        }

        // Use strong=false (default) for short 4-character PIN codes
        // tvOS users must manually type the code at plex.tv/link
        // (Flutter uses strong=true because it can redirect to an auth URL)
        let response: PinResponse = try await request(
            path: "/api/v2/pins",
            method: "POST"
        )

        // Generate auth URL for app.plex.tv/auth (more reliable than plex.tv/link)
        let authURL = generateAuthURL(code: response.code)

        print("🔑 [PIN] Created PIN: \(response.code) (ID: \(response.id))")
        print("🔑 [PIN] Auth URL: \(authURL)")
        print("🔑 [PIN] QR URL: \(response.qr ?? "none")")
        return PlexPin(id: response.id, code: response.code, authToken: nil, authURL: authURL, qrURL: response.qr)
    }

    /// Generate the Plex auth URL for a given PIN code
    /// This URL can be opened on another device to authenticate
    private func generateAuthURL(code: String) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "app.plex.tv"
        components.path = "/auth"

        // Parameters are passed in the fragment (after #?)
        let params = [
            "clientID": Self.plexClientIdentifier,
            "code": code,
            "context[device][product]": Self.plexProduct,
            "context[device][platform]": Self.plexPlatform,
            "context[device][device]": Self.plexDevice
        ]

        let queryString = params
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")

        return "https://app.plex.tv/auth#?\(queryString)"
    }

    func checkPin(id: Int) async throws -> PlexPin {
        // First, get raw response to debug
        let (rawResponse, rawString) = try await requestRawWithString(path: "/api/v2/pins/\(id)")

        // Debug: print all keys to see what Plex returns
        print("🔑 [PIN] Response keys: \(rawResponse.keys.sorted())")

        // Print full raw response for debugging
        if let authTokenValue = rawResponse["authToken"] {
            print("🔑 [PIN] authToken raw value: \(authTokenValue) (type: \(type(of: authTokenValue)))")
        } else {
            print("🔑 [PIN] authToken key missing from response!")
        }

        let pinId = rawResponse["id"] as? Int ?? 0
        let code = rawResponse["code"] as? String ?? ""
        let trusted = rawResponse["trusted"] as? Bool ?? false

        // Handle authToken which might be NSNull from JSON
        var authToken: String? = nil
        if let tokenValue = rawResponse["authToken"] {
            if let token = tokenValue as? String, !token.isEmpty {
                authToken = token
            }
        }

        // Debug logging for PIN status
        let hasToken = authToken.map { !$0.isEmpty } ?? false
        print("🔑 [PIN] Status - trusted: \(trusted), hasToken: \(hasToken), authToken: \(authToken?.prefix(20) ?? "nil")...")

        return PlexPin(id: pinId, code: code, authToken: authToken)
    }

    /// Raw request that returns dictionary and raw string for debugging
    private func requestRawWithString(path: String) async throws -> ([String: Any], String) {
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)

        guard let url = urlComponents?.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // CRITICAL: Bypass cache for PIN checks - we need fresh data from server
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Debug: print the request headers
        print("🔑 [PIN] Request URL: \(url)")
        print("🔑 [PIN] Request headers - X-Plex-Client-Identifier: \(headers["X-Plex-Client-Identifier"] ?? "nil")")

        let (data, response) = try await session.data(for: request)

        // Get raw string for debugging
        let rawString = String(data: data, encoding: .utf8) ?? "unable to decode"

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PlexAPIError.serverError(statusCode: statusCode)
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PlexAPIError.decodingError(NSError(domain: "PlexAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Response is not a dictionary"]))
            }
            return (json, rawString)
        } catch let error as PlexAPIError {
            throw error
        } catch {
            throw PlexAPIError.decodingError(error)
        }
    }

    func getUser() async throws -> PlexUser {
        struct UserResponse: Decodable {
            let id: Int
            let uuid: String
            let username: String
            let title: String
            let email: String?
            let thumb: String?
        }

        let response: UserResponse = try await request(path: "/api/v2/user")
        return PlexUser(
            id: response.id,
            uuid: response.uuid,
            username: response.username,
            title: response.title,
            email: response.email,
            thumb: response.thumb,
            authToken: accessToken
        )
    }

    // MARK: - Server Discovery

    func getServers() async throws -> [PlexServer] {
        // The /api/v2/resources endpoint returns a plain array of resources (not wrapped)
        let queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1")
        ]

        let servers: [PlexServer] = try await requestArray(
            path: "/api/v2/resources",
            queryItems: queryItems
        )
        return servers
    }

    /// Request that returns an array directly (not wrapped in MediaContainer)
    private func requestArray<T: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil
    ) async throws -> [T] {
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        print("🌐 [API] \(method) \(url) (attempt 1/3)")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        print("🌐 [API] Response: \(httpResponse.statusCode) - \(data.count) bytes")

        guard (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.serverError(statusCode: httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([T].self, from: data)
        } catch {
            print("🔴 [API] Array decoding error: \(error)")
            if let dataString = String(data: data, encoding: .utf8) {
                print("🔴 [API] Response data: \(dataString.prefix(500))")
            }
            throw PlexAPIError.decodingError(error)
        }
    }

    // MARK: - Home Users

    func getHomeUsers() async throws -> [PlexHomeUser] {
        struct UsersResponse: Decodable {
            let users: [PlexHomeUser]

            enum CodingKeys: String, CodingKey {
                case users = "users"
            }
        }

        let response: UsersResponse = try await request(path: "/api/v2/home/users")
        return response.users
    }

    func switchHomeUser(userId: Int, pin: String?) async throws -> String {
        struct SwitchRequest: Encodable {
            let pin: String?
        }

        struct SwitchResponse: Decodable {
            let authToken: String
        }

        let body = try JSONEncoder().encode(SwitchRequest(pin: pin))
        let response: SwitchResponse = try await request(
            path: "/api/v2/home/users/\(userId)/switch",
            method: "POST",
            body: body
        )

        return response.authToken
    }

    // MARK: - Device Information Helpers

    private func getSystemVersion() -> String {
        #if os(tvOS)
        return ProcessInfo.processInfo.operatingSystemVersionString
        #else
        return "Unknown"
        #endif
    }

    private func getDeviceName() -> String {
        #if os(tvOS)
        // tvOS doesn't have UIDevice.current.name
        return "Apple TV"
        #else
        return "Unknown Device"
        #endif
    }
}

// MARK: - Errors

enum PlexAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)
    case noData
    case unauthorized
    case notFound
    case rateLimited
    case serverError(statusCode: Int)
    case serverNotReachable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .noData:
            return "No data received"
        case .unauthorized:
            return "Session expired. Please sign in again"
        case .notFound:
            return "Content not found on server"
        case .rateLimited:
            return "Too many requests. Please wait a moment"
        case .serverError(let code):
            return "Server error (\(code)). Please try again later"
        case .serverNotReachable:
            return "Server not reachable"
        }
    }
}
