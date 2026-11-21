import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum IthacaAsyncImagePhase {
    case empty
    case success(Image)
    case failure(any Error)
}

struct IthacaAsyncImage<Content: View>: View {
    @Environment(PlexService.self) private var plexService

    let url: URL?
    @ViewBuilder let content: (IthacaAsyncImagePhase) -> Content

    @State private var phase: IthacaAsyncImagePhase
    /// The URL `phase` was loaded for, so a cell that scrolls back into view
    /// with its image already in memory skips the reload entirely.
    @State private var loadedURL: URL?

    init(url: URL?, @ViewBuilder content: @escaping (IthacaAsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        // A lazy row or grid tears a cell down when it scrolls away. Seeding
        // the first frame from the memory cache means it comes back with its
        // artwork instead of flashing the placeholder for a frame or two.
        let cached = url.flatMap { IthacaImageLoader.shared.cachedImage(for: $0) }
        _phase = State(initialValue: cached.map { .success(Image(uiImage: $0)) } ?? .empty)
        _loadedURL = State(initialValue: cached == nil ? nil : url)
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage()
            }
    }

    @MainActor
    private func loadImage() async {
        guard let url else {
            phase = .empty
            loadedURL = nil
            return
        }

        if loadedURL == url, case .success = phase { return }

        if let cached = IthacaImageLoader.shared.cachedImage(for: url) {
            phase = .success(Image(uiImage: cached))
            loadedURL = url
            return
        }

        phase = .empty
        loadedURL = nil

        do {
            let image = try await IthacaImageLoader.shared.image(for: url, using: plexService)
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: image))
            loadedURL = url
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}

actor IthacaImageLoader {
    static let shared = IthacaImageLoader()

    private let session: URLSession
    #if canImport(UIKit)
    /// NSCache is thread-safe, so the memory cache is read synchronously from
    /// the main actor (`cachedImage(for:)`) without a hop onto this actor.
    nonisolated private let memoryCache = ImageMemoryCache()
    #endif
    /// One download per URL, shared by every view waiting on it. The download
    /// is cancelled when the last of them goes away (a poster scrolled off
    /// screen), so a fast scroll does not leave a queue of transfers for
    /// artwork nobody will see. Keyed by the fetched URL, not the cache key:
    /// after a connection change, a view must not wait on a download from the
    /// address the server just left.
    private var inFlight: [URL: InFlightLoad] = [:]

    private struct InFlightLoad {
        let task: Task<LoadedImage, Error>
        var waiters: Int
    }

    static func memoryCacheByteLimit(for memory: DeviceMemoryClass) -> Int {
        switch memory {
        case .small: 64 << 20
        case .medium: 128 << 20
        case .large: 192 << 20
        }
    }

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = AppImageCache.shared
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30

        session = URLSession(configuration: configuration)
        #if canImport(UIKit)
        memoryCache.countLimit = 512
        // Images are stored decoded (see `decodedImage(from:)`), so bound the
        // cache by bitmap bytes too: a few hundred full-screen backdrops
        // would otherwise pin gigabytes. The bound follows the device's RAM,
        // because the player's buffers and decode surfaces need the rest.
        memoryCache.totalCostLimit = Self.memoryCacheByteLimit(for: .current)
        // NSCache alone does not empty on a memory warning.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [memoryCache] _ in
            memoryCache.removeAllObjects()
        }
        #endif
    }

    /// Empties the decoded-image memory cache. Views keep the images they
    /// show; anything else reloads from the disk cache. Called when the
    /// player opens, so 4K playback does not start on top of up to 192 MB of
    /// artwork nobody is looking at.
    nonisolated func purgeMemory() {
        #if canImport(UIKit)
        memoryCache.removeAllObjects()
        #endif
    }

    /// A fresh decoded image already in memory, or nil. Safe to call from any
    /// thread; never touches disk or the network.
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        #if canImport(UIKit)
        guard let cachedImage = memoryCache.object(forKey: AppImageCache.cacheKey(for: url) as NSURL),
              cachedImage.isFresh else {
            return nil
        }
        return cachedImage.image
        #else
        return nil
        #endif
    }

    func image(for url: URL, using plexService: PlexService? = nil) async throws -> UIImage {
        #if canImport(UIKit)
        let cacheKey = AppImageCache.cacheKey(for: url) as NSURL
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            if cachedImage.isFresh {
                return cachedImage.image
            }
            memoryCache.removeObject(forKey: cacheKey)
        }
        #endif

        if var load = inFlight[url] {
            load.waiters += 1
            inFlight[url] = load
            return try await wait(for: load.task, url: url).image
        }

        // The work runs off this actor: disk reads, network and decoding for
        // one image must not queue every other image behind it.
        let task = Task<LoadedImage, Error>.detached(priority: .userInitiated) { [session] in
            if url.isFileURL {
                let data = try Data(contentsOf: url)
                return LoadedImage(image: try Self.decodedImage(from: data))
            }

            let request = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 30
            )

            if let cachedResponse = AppImageCache.cachedResponse(for: request),
               let cachedImage = try? Self.decodedImage(from: cachedResponse.data) {
                return LoadedImage(
                    image: cachedImage,
                    cachedAt: AppImageCache.cachedAt(for: cachedResponse) ?? .now
                )
            }

            try Task.checkCancellation()
            let data: Data
            if let plexService {
                data = try await plexService.imageData(for: url)
            } else {
                let (fetchedData, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }

                data = fetchedData
                AppImageCache.timestampStoredResponse(for: request)
            }

            return LoadedImage(image: try Self.decodedImage(from: data))
        }

        inFlight[url] = InFlightLoad(task: task, waiters: 1)
        return try await wait(for: task, url: url).image
    }

    private func wait(for task: Task<LoadedImage, Error>, url: URL) async throws -> LoadedImage {
        do {
            let loadedImage = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.releaseWaiter(for: url, task: task) }
            }
            #if canImport(UIKit)
            memoryCache.setObject(
                CachedMemoryImage(image: loadedImage.image, cachedAt: loadedImage.cachedAt),
                forKey: AppImageCache.cacheKey(for: url) as NSURL,
                cost: loadedImage.image.decodedByteCount
            )
            #endif
            if inFlight[url]?.task == task { inFlight[url] = nil }
            return loadedImage
        } catch {
            if inFlight[url]?.task == task { inFlight[url] = nil }
            throw error
        }
    }

    private func releaseWaiter(for url: URL, task: Task<LoadedImage, Error>) {
        guard var load = inFlight[url], load.task == task else { return }
        load.waiters -= 1
        if load.waiters <= 0 {
            inFlight[url] = nil
            task.cancel()
        } else {
            inFlight[url] = load
        }
    }

    /// Decodes the bitmap now, on the calling (background) thread.
    /// `UIImage(data:)` alone is lazy: the JPEG would be decoded on the main
    /// thread the first time the image is drawn, which is a dropped frame per
    /// poster while a row scrolls or focus moves, and a long stall for a
    /// full-screen backdrop.
    nonisolated private static func decodedImage(from data: Data) throws -> UIImage {
        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image.preparingForDisplay() ?? image
    }
}

#if canImport(UIKit)
private extension UIImage {
    var decodedByteCount: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// NSCache is documented as thread-safe but not marked Sendable.
private final class ImageMemoryCache: NSCache<NSURL, CachedMemoryImage>, @unchecked Sendable {}

private struct LoadedImage: @unchecked Sendable {
    let image: UIImage
    let cachedAt: Date

    init(image: UIImage, cachedAt: Date = .now) {
        self.image = image
        self.cachedAt = cachedAt
    }
}

private final class CachedMemoryImage: @unchecked Sendable {
    let image: UIImage
    let cachedAt: Date

    init(image: UIImage, cachedAt: Date = .now) {
        self.image = image
        self.cachedAt = cachedAt
    }

    var isFresh: Bool {
        Date().timeIntervalSince(cachedAt) <= AppImageCache.maxAge
    }
}
#endif
