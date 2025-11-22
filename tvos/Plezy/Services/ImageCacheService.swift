//
//  ImageCacheService.swift
//  Beacon tvOS
//
//  Image caching service to reduce network usage and improve performance
//  Optimized for tvOS memory constraints with aggressive downsampling
//

import SwiftUI
import Combine
import ImageIO
import CryptoKit

/// Manages in-memory and disk-based image caching
/// Optimized for tvOS with aggressive memory management and image downsampling
class ImageCacheService {
    static let shared = ImageCacheService()

    // In-memory cache using NSCache for automatic memory management
    private let memoryCache = NSCache<NSString, UIImage>()

    // Disk cache directory
    private let diskCacheDirectory: URL

    // Track ongoing downloads to avoid duplicate requests
    private var activeDownloads: [URL: Task<UIImage?, Never>] = [:]
    private let downloadLock = NSLock()

    // Optimized URLSession for image downloads
    private let imageSession: URLSession

    // MEMORY LIMITS - Tuned for tvOS (2-3GB RAM available)
    // More generous limits to reduce cache thrashing and re-downloads
    private let memoryCacheCountLimit = 150   // Max 150 images in memory
    private let memoryCacheTotalCostLimit = 150 * 1024 * 1024  // 150 MB max memory
    private let diskCacheSizeLimit = 300 * 1024 * 1024  // 300 MB max disk

    // Maximum image dimensions for downsampling
    // Cards are ~410x231, hero backgrounds need more but 1280 is sufficient for tvOS
    private let maxImageDimension: CGFloat = 1280

    private init() {
        // Configure optimized URLSession for image downloads
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 6 // Balanced concurrent downloads
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,  // 20MB URL cache
            diskCapacity: 50 * 1024 * 1024     // 50MB disk cache
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
        // Check memory cache first
        let cacheKey = url.absoluteString as NSString
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }

        // Check disk cache on background queue to avoid blocking main thread
        if let diskImage = await loadFromDiskAsync(url: url) {
            // Store in memory for faster access next time with proper cost
            let memoryCost = Int(diskImage.size.width * diskImage.size.height * 4)
            memoryCache.setObject(diskImage, forKey: cacheKey, cost: memoryCost)
            return diskImage
        }

        // Check if already downloading (async-safe)
        let existingTask = await withCheckedContinuation { continuation in
            downloadLock.lock()
            let task = activeDownloads[url]
            downloadLock.unlock()
            continuation.resume(returning: task)
        }

        if let existingTask = existingTask {
            return await existingTask.value
        }

        // Create new download task
        let downloadTask = Task<UIImage?, Never> {
            await self.downloadImage(from: url)
        }

        await withCheckedContinuation { continuation in
            downloadLock.lock()
            activeDownloads[url] = downloadTask
            downloadLock.unlock()
            continuation.resume()
        }

        // Wait for download
        let image = await downloadTask.value

        // Clean up task (async-safe)
        await withCheckedContinuation { continuation in
            downloadLock.lock()
            activeDownloads.removeValue(forKey: url)
            downloadLock.unlock()
            continuation.resume()
        }

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

            // Use ImageIO for memory-efficient downsampling
            // This decodes the image at a reduced size, never loading full resolution into memory
            guard let downsampledImage = downsample(data: data, to: maxImageDimension) else {
                // Fallback to regular loading if downsampling fails
                guard let image = UIImage(data: data) else { return nil }
                return image
            }

            // Calculate actual memory cost (width * height * 4 bytes per pixel)
            let memoryCost = Int(downsampledImage.size.width * downsampledImage.size.height * 4)

            // Cache the downsampled image
            let cacheKey = url.absoluteString as NSString
            memoryCache.setObject(downsampledImage, forKey: cacheKey, cost: memoryCost)

            // Save downsampled image to disk asynchronously
            // Use PNG for images with transparency (logos), JPEG for opaque images (photos)
            Task.detached(priority: .background) {
                let hasAlpha = downsampledImage.cgImage?.alphaInfo != .none &&
                               downsampledImage.cgImage?.alphaInfo != .noneSkipFirst &&
                               downsampledImage.cgImage?.alphaInfo != .noneSkipLast

                let imageData: Data?
                if hasAlpha {
                    // PNG preserves transparency for logos
                    imageData = downsampledImage.pngData()
                } else {
                    // JPEG for photos (smaller file size)
                    imageData = downsampledImage.jpegData(compressionQuality: 0.8)
                }

                if let data = imageData {
                    await self.saveToDisk(image: downsampledImage, url: url, data: data)
                }
            }

            return downsampledImage
        } catch {
            return nil
        }
    }

    /// Downsample image using ImageIO for memory efficiency
    /// This is critical - it decodes the image at reduced size, avoiding full-res memory spike
    private func downsample(data: Data, to maxDimension: CGFloat) -> UIImage? {
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
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }

        // Downsample to target size
        let maxPixels = max(width, height) * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else {
            return nil
        }

        return UIImage(cgImage: downsampledImage)
    }

    /// Load image from disk cache (async version - offloads to background queue)
    private func loadFromDiskAsync(url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = self.loadFromDisk(url: url)
                continuation.resume(returning: image)
            }
        }
    }

    /// Load image from disk cache (synchronous - call from background only)
    private func loadFromDisk(url: URL) -> UIImage? {
        let fileURL = diskCacheURL(for: url)

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        // Use downsampling when loading from disk too
        guard let image = downsample(data: data, to: maxImageDimension) else {
            // Fallback to regular loading
            return UIImage(data: data)
        }

        return image
    }

    /// Save image to disk cache
    private func saveToDisk(image: UIImage, url: URL, data: Data) async {
        let fileURL = diskCacheURL(for: url)

        do {
            try data.write(to: fileURL)
            // Clean up old cache if needed
            await cleanDiskCacheIfNeeded()
        } catch {
            // Silently fail - disk cache is optional
        }
    }

    /// Get disk cache file URL for a given image URL
    private func diskCacheURL(for url: URL) -> URL {
        // Use MD5 hash of URL as filename to avoid filesystem issues
        let filename = url.absoluteString.md5Hash
        return diskCacheDirectory.appendingPathComponent(filename)
    }

    /// Clean disk cache if it exceeds size limit
    private func cleanDiskCacheIfNeeded() async {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: diskCacheDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )

            // Calculate total size
            var totalSize: Int64 = 0
            var fileInfos: [(url: URL, size: Int64, date: Date)] = []

            for fileURL in files {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = attributes[.size] as? Int64 ?? 0
                let date = attributes[.modificationDate] as? Date ?? Date.distantPast

                totalSize += size
                fileInfos.append((url: fileURL, size: size, date: date))
            }

            // If under limit, no cleanup needed
            if totalSize <= diskCacheSizeLimit {
                return
            }

            // Sort by date (oldest first)
            fileInfos.sort { $0.date < $1.date }

            // Remove oldest files until under limit
            for fileInfo in fileInfos {
                if totalSize <= diskCacheSizeLimit {
                    break
                }

                try? FileManager.default.removeItem(at: fileInfo.url)
                totalSize -= fileInfo.size
            }
        } catch {
            // Silently fail - cleanup is best effort
        }
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

// MARK: - String MD5 Extension

extension String {
    /// Compute a stable MD5 hash that persists across app launches
    /// Note: String.hashValue is NOT stable across launches due to hash randomization
    var md5Hash: String {
        let data = Data(self.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Cached AsyncImage View

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
