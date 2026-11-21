import Foundation

enum DownloadTransferEvent: Sendable {
    case progress(taskIdentifier: Int, globalKey: String?, progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case paused(taskIdentifier: Int, globalKey: String?, resumeData: Data?)
    case cancelled(taskIdentifier: Int, globalKey: String?)
    case finished(taskIdentifier: Int, globalKey: String?, temporaryURL: URL, response: DownloadTransferResponse?)
    /// `resumeData` is set when URLSession can continue the transfer (a lost
    /// connection, or a force quit reported on the next launch).
    case failed(taskIdentifier: Int, globalKey: String?, error: Error, resumeData: Data?)
}

struct DownloadTransferResponse: Sendable {
    let statusCode: Int?
    let mimeType: String?
    let expectedContentLength: Int64
}

struct DownloadTransferTask: Sendable {
    let identifier: Int
    let globalKey: String?
}

enum DownloadBackgroundSessionRegistry {
    static let identifier = "com.inceptyon.ithaca.downloads.background"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var completionHandlers: [String: () -> Void] = [:]

    static func setCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        lock.lock()
        completionHandlers[identifier] = handler
        lock.unlock()
    }

    static func completeEvents(for identifier: String) {
        lock.lock()
        let handler = completionHandlers.removeValue(forKey: identifier)
        lock.unlock()
        handler?()
    }
}

final class DownloadTransferController: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct ProgressSnapshot {
        let date: Date
    }

    private static let progressEventInterval: TimeInterval = 0.75

    private let eventHandler: @Sendable (DownloadTransferEvent) -> Void
    private let stateLock = NSLock()
    private var pausedTaskIdentifiers: Set<Int> = []
    private var cancelledTaskIdentifiers: Set<Int> = []
    private var progressSnapshots: [Int: ProgressSnapshot] = [:]
    /// Finished transfers the manager has not recorded yet. The background
    /// session's completion handler waits for them, since iOS may suspend the
    /// app as soon as it runs.
    private var unrecordedFinishedTransfers = 0
    private var pendingBackgroundEventsIdentifier: String?
    private lazy var session: URLSession = {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: DownloadBackgroundSessionRegistry.identifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #else
        let configuration = URLSessionConfiguration.default
        #endif
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(eventHandler: @escaping @Sendable (DownloadTransferEvent) -> Void) {
        self.eventHandler = eventHandler
        super.init()
        _ = session
    }

    func start(
        request: URLRequest,
        resumeData: Data?,
        globalKey: String
    ) -> Int {
        let task: URLSessionDownloadTask
        if let resumeData {
            // Resume data replays the original request: its address, token and
            // Wi-Fi Only flag. Point it at the current request instead.
            task = session.downloadTask(
                withResumeData: DownloadResumeData.retargeted(resumeData, to: request) ?? resumeData
            )
        } else {
            task = session.downloadTask(with: request)
        }
        task.taskDescription = globalKey
        task.resume()
        return task.taskIdentifier
    }

    func pause(taskIdentifier: Int) {
        findDownloadTask(taskIdentifier: taskIdentifier) { [weak self] task in
            guard let self, let task else { return }
            self.stateLock.lock()
            self.pausedTaskIdentifiers.insert(taskIdentifier)
            self.stateLock.unlock()
            task.cancel(byProducingResumeData: { resumeData in
                self.eventHandler(.paused(
                    taskIdentifier: taskIdentifier,
                    globalKey: task.taskDescription,
                    resumeData: resumeData
                ))
            })
        }
    }

    /// Whether cancelling the task would produce resume data: the server
    /// answered 200/206 with `Accept-Ranges: bytes` and a validator. A task
    /// with no response yet has nothing to lose.
    func isResumable(taskIdentifier: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            findDownloadTask(taskIdentifier: taskIdentifier) { task in
                guard let task else {
                    continuation.resume(returning: false)
                    return
                }
                guard let response = task.response as? HTTPURLResponse else {
                    continuation.resume(returning: true)
                    return
                }
                let acceptsRanges = (response.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
                    .lowercased() == "bytes"
                let hasValidator = response.value(forHTTPHeaderField: "ETag") != nil
                    || response.value(forHTTPHeaderField: "Last-Modified") != nil
                continuation.resume(returning: [200, 206].contains(response.statusCode) && acceptsRanges && hasValidator)
            }
        }
    }

    func cancel(taskIdentifier: Int) {
        findDownloadTask(taskIdentifier: taskIdentifier) { [weak self] task in
            guard let self, let task else { return }
            self.stateLock.lock()
            self.cancelledTaskIdentifiers.insert(taskIdentifier)
            self.stateLock.unlock()
            task.cancel()
        }
    }

    func existingTasks() async -> [DownloadTransferTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let downloads = tasks.compactMap { task -> DownloadTransferTask? in
                    guard task is URLSessionDownloadTask else { return nil }
                    return DownloadTransferTask(
                        identifier: task.taskIdentifier,
                        globalKey: task.taskDescription
                    )
                }
                continuation.resume(returning: downloads)
            }
        }
    }

    private func findDownloadTask(
        taskIdentifier: Int,
        completion: @escaping @Sendable (URLSessionDownloadTask?) -> Void
    ) {
        session.getAllTasks { tasks in
            let task = tasks.first { $0.taskIdentifier == taskIdentifier } as? URLSessionDownloadTask
            completion(task)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        let progressValue: Double
        if totalBytes > 0 {
            progressValue = min(max(Double(totalBytesWritten) / Double(totalBytes), 0), 1)
        } else {
            progressValue = 0
        }

        stateLock.lock()
        let now = Date()
        let previous = progressSnapshots[downloadTask.taskIdentifier]
        let isComplete = totalBytes > 0 && totalBytesWritten >= totalBytes
        let shouldEmit = previous == nil
            || isComplete
            || now.timeIntervalSince(previous?.date ?? .distantPast) >= Self.progressEventInterval
        if shouldEmit {
            progressSnapshots[downloadTask.taskIdentifier] = ProgressSnapshot(
                date: now
            )
        }
        stateLock.unlock()

        guard shouldEmit else { return }

        eventHandler(.progress(
            taskIdentifier: downloadTask.taskIdentifier,
            globalKey: downloadTask.taskDescription,
            progress: progressValue,
            downloadedBytes: totalBytesWritten,
            totalBytes: totalBytes
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let stableLocation = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: stableLocation)
            stateLock.lock()
            unrecordedFinishedTransfers += 1
            stateLock.unlock()
            let httpResponse = downloadTask.response as? HTTPURLResponse
            eventHandler(.finished(
                taskIdentifier: downloadTask.taskIdentifier,
                globalKey: downloadTask.taskDescription,
                temporaryURL: stableLocation,
                response: DownloadTransferResponse(
                    statusCode: httpResponse?.statusCode,
                    mimeType: downloadTask.response?.mimeType,
                    expectedContentLength: downloadTask.response?.expectedContentLength ?? -1
                )
            ))
        } catch {
            eventHandler(.failed(
                taskIdentifier: downloadTask.taskIdentifier,
                globalKey: downloadTask.taskDescription,
                error: error,
                resumeData: nil
            ))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let wasPaused = pausedTaskIdentifiers.remove(task.taskIdentifier) != nil
        let wasCancelled = cancelledTaskIdentifiers.remove(task.taskIdentifier) != nil
        progressSnapshots.removeValue(forKey: task.taskIdentifier)
        stateLock.unlock()

        if wasPaused {
            return
        }

        if wasCancelled {
            eventHandler(.cancelled(
                taskIdentifier: task.taskIdentifier,
                globalKey: task.taskDescription
            ))
            return
        }

        if let error {
            eventHandler(.failed(
                taskIdentifier: task.taskIdentifier,
                globalKey: task.taskDescription,
                error: error,
                resumeData: (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            ))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        stateLock.lock()
        let waitsForManager = unrecordedFinishedTransfers > 0
        if waitsForManager {
            pendingBackgroundEventsIdentifier = identifier
        }
        stateLock.unlock()
        guard !waitsForManager else { return }
        // UIKit requires the completion handler on the main thread.
        Task { @MainActor in
            DownloadBackgroundSessionRegistry.completeEvents(for: identifier)
        }
    }

    /// Called once per `.finished` event, after the manager has stored its
    /// outcome; releases a background completion handler waiting on it.
    func finishedTransferWasRecorded() {
        stateLock.lock()
        unrecordedFinishedTransfers = max(unrecordedFinishedTransfers - 1, 0)
        let identifier = unrecordedFinishedTransfers == 0 ? pendingBackgroundEventsIdentifier : nil
        if identifier != nil {
            pendingBackgroundEventsIdentifier = nil
        }
        stateLock.unlock()
        guard let identifier else { return }
        Task { @MainActor in
            DownloadBackgroundSessionRegistry.completeEvents(for: identifier)
        }
    }
}

/// Rewrites the requests archived inside URLSession resume data, so a resumed
/// transfer uses the current address, token and network constraints while
/// keeping URLSession's own Range and If-Range headers. The format is not
/// documented: on anything unexpected this returns nil and the caller resumes
/// with the data unchanged.
enum DownloadResumeData {
    private static let archiveRootKey = "NSKeyedArchiveRootObjectKey"
    private static let requestKeys = ["NSURLSessionResumeCurrentRequest", "NSURLSessionResumeOriginalRequest"]

    static func retargeted(_ data: Data, to request: URLRequest) -> Data? {
        // Current OS releases wrap the dictionary in a keyed archive; older
        // ones store it as a plain property list.
        if let (info, rootKey) = archivedResumeInfo(data) {
            guard let updated = retargeted(info, to: request) else { return nil }
            return archive(updated as NSDictionary, forKey: rootKey, secure: false)
        }
        guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let updated = retargeted(info, to: request) else {
            return nil
        }
        return try? PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
    }

    /// CFNetwork archives under the literal "NSKeyedArchiveRootObjectKey"
    /// rather than Foundation's "root"; both are tried.
    private static var rootKeys: [String] { [archiveRootKey, NSKeyedArchiveRootObjectKey] }

    private static func archivedResumeInfo(_ data: Data) -> ([String: Any], String)? {
        for key in rootKeys {
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            // The data is URLSession's own, saved by this app.
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            if let info = unarchiver.decodeObject(forKey: key) as? [String: Any] {
                return (info, key)
            }
        }
        return nil
    }

    private static func archivedRequest(_ data: Data) -> (NSURLRequest, String)? {
        for key in rootKeys {
            // NSURLRequest only decodes through secure coding.
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            defer { unarchiver.finishDecoding() }
            if let request = unarchiver.decodeObject(of: [NSURLRequest.self, NSMutableURLRequest.self], forKey: key) as? NSURLRequest {
                return (request, key)
            }
        }
        return nil
    }

    private static func archive(_ object: Any, forKey key: String, secure: Bool) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: secure)
        archiver.encode(object, forKey: key)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func retargeted(_ info: [String: Any], to request: URLRequest) -> [String: Any]? {
        guard let url = request.url else { return nil }
        var info = info
        var rewroteRequest = false
        for key in requestKeys {
            guard let archived = info[key] as? Data,
                  let (stored, rootKey) = archivedRequest(archived),
                  let updated = stored.mutableCopy() as? NSMutableURLRequest else {
                continue
            }
            updated.url = url
            for (field, value) in request.allHTTPHeaderFields ?? [:] {
                updated.setValue(value, forHTTPHeaderField: field)
            }
            updated.allowsCellularAccess = request.allowsCellularAccess
            updated.allowsExpensiveNetworkAccess = request.allowsExpensiveNetworkAccess
            updated.allowsConstrainedNetworkAccess = request.allowsConstrainedNetworkAccess
            info[key] = archive(updated, forKey: rootKey, secure: true)
            rewroteRequest = true
        }
        guard rewroteRequest else { return nil }
        if info["NSURLSessionDownloadURL"] != nil {
            info["NSURLSessionDownloadURL"] = url.absoluteString
        }
        return info
    }
}
