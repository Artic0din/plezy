//
//  ImageCacheService.swift
//  Beacon tvOS
//
//  Image caching service to reduce network usage and improve performance
//  Optimized for tvOS memory constraints with aggressive downsampling
//

import UIKit
import ImageIO
import CryptoKit

// MARK: - String MD5 Extension

extension String {
    /// Compute a stable MD5 hash that persists across app launches
    /// Note: String.hashValue is NOT stable across launches due to hash randomization
    /// Marked nonisolated to allow use from any context without actor isolation
    nonisolated var md5Hash: String {
        let data = Data(self.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Disk Cache Helpers (Sendable, nonisolated)

/// These helper functions perform disk I/O and are explicitly nonisolated.
/// They work only with Sendable types (Data, URL, CGFloat) and return Data or nil.
/// UIImage creation happens separately to avoid actor isolation issues.

/// Compute the disk cache file URL for a given image URL
private nonisolated func computeDiskCacheURL(for url: URL, in directory: URL) -> URL {
    let filename = url.absoluteString.md5Hash
    return directory.appendingPathComponent(filename)
}

/// Load image data from disk synchronously - returns raw Data, not UIImage
/// This avoids actor isolation issues since Data is Sendable
private nonisolated func loadImageDataFromDisk(for url: URL, cacheDirectory: URL) -> Data? {
    let fileURL = computeDiskCacheURL(for: url, in: cacheDirectory)
    return try? Data(contentsOf: fileURL)
}

/// Save image data to disk synchronously
private nonisolated func saveImageDataToDisk(_ data: Data, for url: URL, in directory: URL) {
    let fileURL = computeDiskCacheURL(for: url, in: directory)
    try? data.write(to: fileURL)
}

/// Downsample image data using ImageIO for memory efficiency
/// Returns CGImage which is Sendable, conversion to UIImage happens on caller's context
private nonisolated func downsampleImageDataToCGImage(_ data: Data, to maxDimension: CGFloat) -> CGImage? {
    let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
        return nil
    }

    // Get original image dimensions
    guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
          let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
        return nil
    }

    // Calculate scale factor to fit within maxDimension
    let scale = min(maxDimension / max(width, height), 1.0)

    // If image is already small enough, decode at full size
    if scale >= 1.0 {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(imageSource, 0, options)
    }

    // Downsample to target size
    let maxPixels = max(width, height) * scale
    let downsampleOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels
    ] as CFDictionary

    return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions)
}

/// Encode UIImage to Data for disk storage (must be called where UIImage is available)
private nonisolated func encodeImageToData(_ cgImage: CGImage, hasAlpha: Bool) -> Data? {
    let image = UIImage(cgImage: cgImage)
    if hasAlpha {
        return image.pngData()
    } else {
        return image.jpegData(compressionQuality: 0.8)
    }
}

// MARK: - Download Tracking Actor

/// Actor to safely track ongoing downloads without NSLock
private actor DownloadTracker {
    private var activeDownloads: [URL: Task<UIImage?, Never>] = [:]

    func getExistingTask(for url: URL) -> Task<UIImage?, Never>? {
        return activeDownloads[url]
    }

    func setTask(_ task: Task<UIImage?, Never>, for url: URL) {
        activeDownloads[url] = task
    }

    func removeTask(for url: URL) {
        activeDownloads.removeValue(forKey: url)
    }
}

// MARK: - ImageCacheService

/// Manages in-memory and disk-based image caching
/// Optimized for tvOS with aggressive memory management and image downsampling
///
/// Architecture notes:
/// - Uses DownloadTracker actor for thread-safe download management
/// - Memory cache uses NSCache which is thread-safe
/// - Disk operations are performed via detached tasks using nonisolated helper functions
/// - Helper functions work with Sendable types (Data, CGImage) to avoid actor isolation issues
final class ImageCacheService: @unchecked Sendable {
    static let shared = ImageCacheService()

    // In-memory cache using NSCache for automatic memory management
    // NSCache is thread-safe so we can use @unchecked Sendable
    private let memoryCache = NSCache<NSString, UIImage>()

    // Disk cache directory
    private let diskCacheDirectory: URL

    // Track ongoing downloads using actor for Swift Concurrency safety
    private let downloadTracker = DownloadTracker()

    // Optimized URLSession for image downloads
    private let imageSession: URLSession

    // MEMORY LIMITS - Tuned for tvOS (2-3GB RAM available)
    private let memoryCacheCountLimit = 150
    private let memoryCacheTotalCostLimit = 150 * 1024 * 1024  // 150 MB
    private let diskCacheSizeLimit = 300 * 1024 * 1024  // 300 MB

    // Maximum image dimensions for downsampling
    private let maxImageDimension: CGFloat = 1280

    private init() {
        // Configure optimized URLSession for image downloads
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024
        )
        self.imageSession = URLSession(configuration: configuration)

        // Set up memory cache limits
        memoryCache.countLimit = memoryCacheCountLimit
        memoryCache.totalCostLimit = memoryCacheTotalCostLimit

        // Set up disk cache directory
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheDirectory = cacheDir.appendingPathComponent("ImageCache")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)

        // Register for memory warnings to clear cache
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        print("🖼️ [ImageCache] Initialized - Memory: \(memoryCacheTotalCostLimit / 1024 / 1024)MB, Disk: \(diskCacheSizeLimit / 1024 / 1024)MB, MaxDim: \(Int(maxImageDimension))")
    }

    @objc private func handleMemoryWarning() {
        print("⚠️ [ImageCache] Memory warning received - clearing memory cache")
        memoryCache.removeAllObjects()
    }

    /// Fetch image from cache or download it
    func image(for url: URL) async -> UIImage? {
        // Check memory cache first (NSCache is thread-safe)
        let cacheKey = url.absoluteString as NSString
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }

        // Check disk cache
        if let diskImage = await loadFromDiskAsync(url: url) {
            let memoryCost = Int(diskImage.size.width * diskImage.size.height * 4)
            memoryCache.setObject(diskImage, forKey: cacheKey, cost: memoryCost)
            return diskImage
        }

        // Check if already downloading (actor-safe)
        if let existingTask = await downloadTracker.getExistingTask(for: url) {
            return await existingTask.value
        }

        // Create new download task
        let downloadTask = Task<UIImage?, Never> {
            await self.downloadImage(from: url)
        }

        await downloadTracker.setTask(downloadTask, for: url)

        // Wait for download
        let image = await downloadTask.value

        // Clean up task
        await downloadTracker.removeTask(for: url)

        return image
    }

    /// Download image from URL with automatic downsampling for memory efficiency
    private func downloadImage(from url: URL) async -> UIImage? {
        do {
            let (data, response) = try await imageSession.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            // Downsample using nonisolated helper (returns CGImage which is Sendable)
            guard let cgImage = downsampleImageDataToCGImage(data, to: maxImageDimension) else {
                // Fallback to regular loading
                return UIImage(data: data)
            }

            let downsampledImage = UIImage(cgImage: cgImage)

            // Calculate actual memory cost
            let memoryCost = Int(downsampledImage.size.width * downsampledImage.size.height * 4)

            // Cache the downsampled image
            let cacheKey = url.absoluteString as NSString
            memoryCache.setObject(downsampledImage, forKey: cacheKey, cost: memoryCost)

            // Save to disk in background
            let cacheDir = self.diskCacheDirectory
            let hasAlpha = cgImage.alphaInfo != .none &&
                           cgImage.alphaInfo != .noneSkipFirst &&
                           cgImage.alphaInfo != .noneSkipLast

            // Encode image data now (before detached task) to avoid UIImage in detached context
            if let imageData = encodeImageToData(cgImage, hasAlpha: hasAlpha) {
                Task.detached(priority: .background) {
                    saveImageDataToDisk(imageData, for: url, in: cacheDir)
                }
            }

            return downsampledImage
        } catch {
            return nil
        }
    }

    /// Load image from disk cache asynchronously
    private func loadFromDiskAsync(url: URL) async -> UIImage? {
        let cacheDir = self.diskCacheDirectory
        let maxDim = self.maxImageDimension

        // Use Task.detached to run disk I/O off the main actor
        return await Task.detached(priority: .userInitiated) {
            // Load raw data from disk (nonisolated, Sendable)
            guard let data = loadImageDataFromDisk(for: url, cacheDirectory: cacheDir) else {
                return nil
            }

            // Downsample to CGImage (nonisolated, Sendable)
            if let cgImage = downsampleImageDataToCGImage(data, to: maxDim) {
                return UIImage(cgImage: cgImage)
            }

            // Fallback
            return UIImage(data: data)
        }.value
    }

    /// Clean disk cache if it exceeds size limit
    func cleanDiskCacheIfNeeded() async {
        let cacheDir = self.diskCacheDirectory
        let sizeLimit = self.diskCacheSizeLimit

        await Task.detached(priority: .background) {
            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: cacheDir,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
                )

                var totalSize: Int64 = 0
                var fileInfos: [(url: URL, size: Int64, date: Date)] = []

                for fileURL in files {
                    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let size = attributes[.size] as? Int64 ?? 0
                    let date = attributes[.modificationDate] as? Date ?? Date.distantPast

                    totalSize += size
                    fileInfos.append((url: fileURL, size: size, date: date))
                }

                if totalSize <= sizeLimit {
                    return
                }

                fileInfos.sort { $0.date < $1.date }

                for fileInfo in fileInfos {
                    if totalSize <= sizeLimit {
                        break
                    }
                    try? FileManager.default.removeItem(at: fileInfo.url)
                    totalSize -= fileInfo.size
                }
            } catch {
                // Silently fail - cleanup is best effort
            }
        }.value
    }

    /// Clear all cached images
    func clearAll() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheDirectory)
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }

    /// Prefetch images for better performance
    func prefetch(urls: [URL]) {
        Task {
            for url in urls {
                _ = await image(for: url)
            }
        }
    }
}

// MARK: - Cached AsyncImage View

import SwiftUI

/// Drop-in replacement for AsyncImage that uses image caching
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var isLoading = true

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = image {
                content(Image(uiImage: image))
            } else if isLoading {
                placeholder()
            } else {
                placeholder()
            }
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url = url else {
            isLoading = false
            return
        }

        let cachedImage = await ImageCacheService.shared.image(for: url)
        self.image = cachedImage
        self.isLoading = false
    }
}

// MARK: - Convenience initializer matching AsyncImage API

extension CachedAsyncImage where Content == Image, Placeholder == EmptyView {
    init(url: URL?) {
        self.init(
            url: url,
            content: { $0.resizable() },
            placeholder: { EmptyView() }
        )
    }
}
