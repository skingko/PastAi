import AppKit

/// macOS has no pasteboard change notification, so `changeCount` is polled. Reading that integer is cheap
/// and does not touch content; a short interval keeps quick successive copies from being missed.
@MainActor
public final class PasteboardMonitor {
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int

    public var onChange: (() -> Void)?

    public init(pasteboard: NSPasteboard = .general, interval: TimeInterval = 0.25) {
        self.pasteboard = pasteboard
        self.interval = interval
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        onChange?()
    }

    /// Treats whatever is on the pasteboard now as already seen.
    public func acknowledgeCurrentContents() {
        lastChangeCount = pasteboard.changeCount
    }
}

@MainActor
public final class CaptureService {
    private let service: ClipService
    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private let monitor: PasteboardMonitor
    private var pipeline: Task<Void, Never>?

    /// Called with new clips, after they are stored, so enrichment can pick them up.
    public var onCaptured: ((Int64) -> Void)?

    /// While true, pasteboard changes are skipped. Set around a borrow of the pasteboard.
    public var isSuspended = false

    public init(service: ClipService, settings: AppSettings, pasteboard: NSPasteboard = .general) {
        self.service = service
        self.settings = settings
        self.pasteboard = pasteboard
        monitor = PasteboardMonitor(pasteboard: pasteboard)
        monitor.onChange = { [weak self] in self?.handleChange() }
    }

    public func start() { monitor.start() }
    public func stop() { monitor.stop() }

    /// Waits for captures already queued. Used by tests.
    public func drain() async { await pipeline?.value }

    public func poll() { monitor.poll() }

    /// For code that borrows the pasteboard briefly and puts it back, so neither step reaches the history.
    public func acknowledgeCurrentContents() { monitor.acknowledgeCurrentContents() }

    /// Decides from the type list alone, so ignored content is never read into memory at all.
    func shouldCapture(types: Set<String>, frontmostBundleID: String?) -> Bool {
        if settings.isPaused { return false }
        if types.contains(PasteWriter.internalMarker.rawValue) { return false }
        if !types.isDisjoint(with: PasteboardTypes.transient) { return false }
        if settings.ignoreConcealed, !types.isDisjoint(with: PasteboardTypes.concealed) { return false }
        if let frontmostBundleID, settings.ignoredBundleIDs.contains(frontmostBundleID) { return false }
        return true
    }

    private func handleChange() {
        guard !isSuspended else { return }
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard shouldCapture(types: types, frontmostBundleID: frontmost?.bundleIdentifier) else { return }

        let source = SourceInfo(bundleID: frontmost?.bundleIdentifier, name: frontmost?.localizedName)
        let expectedCount = pasteboard.changeCount
        let limit = settings.snapshotLimitBytes
        nonisolated(unsafe) let board = pasteboard
        let service = service
        let previous = pipeline
        pipeline = Task.detached(priority: .userInitiated) { [weak self] in
            await previous?.value
            let snapshot = PasteboardReader.read(board)
            // A newer copy landed mid-read and may have mixed types; the next poll captures it cleanly.
            guard board.changeCount == expectedCount else { return }
            guard let draft = ClipBuilder.build(snapshot, source: source) else { return }
            guard let result = try? await service.ingest(draft), result.isNew else { return }
            await self?.didCapture(result.clipID)
            await FileSnapshotter(service: service).snapshotFiles(of: result.clipID, limit: limit)
        }
    }

    private func didCapture(_ clipID: Int64) {
        onCaptured?(clipID)
    }
}

/// Keeps a private copy of small files so a clip survives the original being moved or deleted.
public struct FileSnapshotter: Sendable {
    let service: ClipService

    public init(service: ClipService) { self.service = service }

    public func snapshotFiles(of clipID: Int64, limit: Int64) async {
        guard let detail = try? await service.detail(id: clipID) else { return }
        let directory = service.paths.files.appending(path: String(clipID), directoryHint: .isDirectory)
        for file in detail.files where !file.isDirectory && file.byteSize <= limit {
            let source = URL(fileURLWithPath: file.originalPath)
            let relative = "\(clipID)/\(file.position)-\(file.fileName)"
            let destination = service.paths.files.appending(path: relative)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // clonefile shares blocks on the same APFS volume, so even a large file costs no space.
                if clonefile(source.path, destination.path, 0) != 0 {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                try await service.setSnapshot(fileID: file.id, relativePath: relative)
            } catch {
                continue
            }
        }
    }
}
