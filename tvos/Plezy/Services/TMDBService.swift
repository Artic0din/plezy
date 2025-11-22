//
//  TMDBService.swift
//  Beacon tvOS
//
//  TMDB API client for fetching network logos and additional metadata
//

import Foundation
import UIKit

/// Information about a TV network from TMDB
struct TMDBNetwork: Codable {
    let id: Int
    let name: String
    let logoPath: String?
    let originCountry: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case logoPath = "logo_path"
        case originCountry = "origin_country"
    }
}

/// Response from TMDB /tv/{tv_id} endpoint
private struct TMDBTVShowResponse: Codable {
    let id: Int
    let name: String
    let networks: [TMDBNetwork]?
}

/// Actor-based cache for network logos to avoid refetching
actor NetworkLogoCache {
    static let shared = NetworkLogoCache()

    // Cache by TMDB network ID -> logo URL
    private var logoURLCache: [Int: URL] = [:]

    // Cache by TMDB TV show ID -> primary network info
    private var tvShowNetworkCache: [Int: TMDBNetwork?] = [:]

    private init() {}

    func getCachedLogoURL(forNetworkId networkId: Int) -> URL? {
        return logoURLCache[networkId]
    }

    func cacheLogoURL(_ url: URL, forNetworkId networkId: Int) {
        logoURLCache[networkId] = url
    }

    func getCachedNetwork(forTVShowId tvShowId: Int) -> TMDBNetwork?? {
        // Returns nil if not cached, Optional(nil) if cached but no network
        if tvShowNetworkCache.keys.contains(tvShowId) {
            return tvShowNetworkCache[tvShowId]
        }
        return nil
    }

    func cacheNetwork(_ network: TMDBNetwork?, forTVShowId tvShowId: Int) {
        tvShowNetworkCache[tvShowId] = network
    }
}

/// TMDB API service for fetching metadata
class TMDBService {
    static let shared = TMDBService()

    private let apiKey = "YOUR_TMDB_API_KEY"  // Replace with actual API key
    private let baseURL = "https://api.themoviedb.org/3"
    private let imageBaseURL = "https://image.tmdb.org/t/p"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// Fetches the primary network logo URL for a TV show
    /// - Parameter tmdbTVId: The TMDB TV show ID
    /// - Returns: URL to the network logo, or nil if not available
    func fetchPrimaryNetworkLogoURL(forTVId tmdbTVId: Int) async -> URL? {
        // Check if we've already fetched this TV show's network
        if let cachedResult = await NetworkLogoCache.shared.getCachedNetwork(forTVShowId: tmdbTVId) {
            // We have a cached result (could be nil if no network)
            if let network = cachedResult, let logoPath = network.logoPath {
                // Check if we have the logo URL cached
                if let cachedLogoURL = await NetworkLogoCache.shared.getCachedLogoURL(forNetworkId: network.id) {
                    return cachedLogoURL
                }
                // Build and cache the logo URL
                let logoURL = buildImageURL(path: logoPath, size: "w154")
                if let logoURL = logoURL {
                    await NetworkLogoCache.shared.cacheLogoURL(logoURL, forNetworkId: network.id)
                }
                return logoURL
            }
            return nil
        }

        // Fetch from TMDB
        do {
            let network = try await fetchPrimaryNetwork(forTVId: tmdbTVId)
            await NetworkLogoCache.shared.cacheNetwork(network, forTVShowId: tmdbTVId)

            guard let network = network, let logoPath = network.logoPath else {
                return nil
            }

            // Check if another TV show already cached this network's logo
            if let cachedLogoURL = await NetworkLogoCache.shared.getCachedLogoURL(forNetworkId: network.id) {
                return cachedLogoURL
            }

            let logoURL = buildImageURL(path: logoPath, size: "w154")
            if let logoURL = logoURL {
                await NetworkLogoCache.shared.cacheLogoURL(logoURL, forNetworkId: network.id)
            }
            return logoURL
        } catch {
            #if DEBUG
            print("🎬 [TMDB] Error fetching network for TV show \(tmdbTVId): \(error)")
            #endif
            // Cache nil to avoid refetching on error
            await NetworkLogoCache.shared.cacheNetwork(nil, forTVShowId: tmdbTVId)
            return nil
        }
    }

    /// Fetches the primary network for a TV show from TMDB
    private func fetchPrimaryNetwork(forTVId tmdbTVId: Int) async throws -> TMDBNetwork? {
        let urlString = "\(baseURL)/tv/\(tmdbTVId)?api_key=\(apiKey)&language=en"
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }

        #if DEBUG
        print("🎬 [TMDB] Fetching TV show info: \(tmdbTVId)")
        #endif

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw TMDBError.requestFailed
        }

        let decoder = JSONDecoder()
        let tvShow = try decoder.decode(TMDBTVShowResponse.self, from: data)

        #if DEBUG
        if let network = tvShow.networks?.first {
            print("🎬 [TMDB] Primary network: \(network.name) (id: \(network.id))")
        } else {
            print("🎬 [TMDB] No networks found for TV show \(tmdbTVId)")
        }
        #endif

        return tvShow.networks?.first
    }

    /// Builds a TMDB image URL
    /// - Parameters:
    ///   - path: The image path from TMDB (e.g., "/pbpMk2JmcoNnQwN5JGpKihwgKgg.png")
    ///   - size: The image size (e.g., "w92", "w154", "w185", "w300", "w500", "original")
    private func buildImageURL(path: String, size: String) -> URL? {
        return URL(string: "\(imageBaseURL)/\(size)\(path)")
    }
}

enum TMDBError: Error {
    case invalidURL
    case requestFailed
    case decodingError
}
