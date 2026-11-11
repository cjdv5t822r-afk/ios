import Foundation
import Observation
import StageCore

/// How a download ended. Told once, to `PackLibrary.onEvent`.
enum LibraryEvent {
    /// The pack is on the phone and in the repository's list.
    case installed(CharacterPack)
    case failed(RemotePack, DownloadError)
}

/// The character library: what the pack server offers (`catalog`) and the downloads in progress (`downloads`).
/// Packs that are already on the phone are listed by `PackRepository`. Port of `content/PackLibrary.kt`.
///
/// On Android this state is kept once per process behind a lock, because downloads outlive the screen that
/// started them. Here the one view model lives as long as the app, and everything below runs on the main actor,
/// which takes the place of that lock; the network and the files are worked on elsewhere (`PackInstaller`).
@MainActor
@Observable
final class PackLibrary {

    static let maxParallelDownloads = 2

    /// A server that trickles the list out byte by byte never trips the idle timeout, and a fetch that is running
    /// can be neither cancelled nor started again, so the whole of it gets a deadline.
    static let defaultCatalogTimeout: Duration = .seconds(45)

    /// What the pack server offers, or how far fetching that has got.
    private(set) var catalog: CatalogState = .idle

    /// The catalog that arrived last, as the list shows it (by name, with search keys). It stays while a refresh
    /// takes `catalog` through `.loading`, so the rows neither blink nor lose their place. Nil until the first
    /// catalog has arrived.
    private(set) var entries: [LibraryEntry]? = nil

    /// Downloads in flight and failed ones, by pack id.
    private(set) var downloads: [String: DownloadState] = [:]

    /// Whether any download is running. Kept apart from `downloads`, so that a view that only needs the yes or
    /// no is not redrawn for every percent of progress.
    private(set) var isDownloading = false

    /// Called on the main actor when a download has ended with a pack or with a failure.
    @ObservationIgnored var onEvent: ((LibraryEvent) -> Void)?

    private struct Job {
        let token: Int
        let task: Task<Void, Never>
    }

    private enum CatalogOutcome: Sendable {
        case ready([RemotePack], [LibraryEntry])
        case failed(CatalogError)
        case timedOut
    }

    /// Files that are not what the list says usually mean that the list is the stale part.
    private static let staleCatalogSigns: [DownloadError] = [.checksum, .tooLarge, .server]

    @ObservationIgnored private let installer: PackInstaller
    @ObservationIgnored private let repository: PackRepository
    @ObservationIgnored private let catalogTimeout: Duration

    /// Leftovers of a killed process are cleared before the first download can create its own staging folder.
    @ObservationIgnored private let recovery: Task<Void, Never>

    /// The download that owns each pack id, until it has ended, was called off, or a newer download of the pack
    /// has taken its place.
    @ObservationIgnored private var jobs: [String: Job] = [:]
    @ObservationIgnored private var lastToken = 0
    @ObservationIgnored private var catalogFetch: Task<Void, Never>?
    @ObservationIgnored private var activeDownloads = 0
    @ObservationIgnored private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        repository: PackRepository,
        baseURL: String? = PackServer.baseURL,
        catalogTimeout: Duration = PackLibrary.defaultCatalogTimeout
    ) {
        let directory = PackRepository.packsDirectory
        self.repository = repository
        self.catalogTimeout = catalogTimeout
        installer = PackInstaller(packsDirectory: directory, base: baseURL, transport: PackTransport(base: baseURL))
        recovery = Task.detached(priority: .userInitiated) { PackStore.recover(directory) }
    }

    /// Returns once the leftovers of a killed process are cleared from the packs folder. Only then is the list
    /// of packs on the phone complete, and only then may an import create its own staging folder there.
    func awaitRecovery() async {
        await recovery.value
    }

    // MARK: catalog

    /// Fetches the catalog again; returns when `catalog` holds the outcome. A fetch that is already running is
    /// joined instead of doubled.
    func refreshCatalog() async {
        if let running = catalogFetch {
            await running.value
            return
        }
        let fetch = Task { [weak self] in
            await self?.loadCatalog()
            self?.catalogFetch = nil
        }
        catalogFetch = fetch
        await fetch.value
    }

    private func loadCatalog() async {
        catalog = .loading
        let installer = self.installer
        let timeout = catalogTimeout
        let outcome = await withTaskGroup(of: CatalogOutcome.self) { group -> CatalogOutcome in
            group.addTask {
                do {
                    let packs = try await installer.fetchCatalog()
                    // Sorted here, off the main actor: a full catalog is two thousand names.
                    return .ready(packs, LibraryRules.entries(packs))
                } catch let failure as CatalogFailure {
                    return .failed(failure.error)
                } catch is CancellationError {
                    return .timedOut
                } catch {
                    // Whatever a hostile document manages to trip over, it is the document that is bad.
                    return .failed(.badData)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            // Ends the wait when the catalog came first, and the request when the deadline did.
            group.cancelAll()
            return first
        }
        switch outcome {
        case .ready(let packs, let sorted):
            entries = sorted
            catalog = .ready(packs)
        case .failed(let error):
            catalog = .failed(error)
        case .timedOut:
            catalog = .failed(.offline)
        }
    }

    // MARK: downloads

    /// Starts downloading `pack`. Ignored while a download of the same pack is running.
    func download(_ pack: RemotePack) {
        // A cancelled download of this pack may still be letting go of the network. The new one does not wait
        // for it: each has a staging folder of its own, and a cancelled one never puts a pack in place.
        if jobs[pack.id] != nil { return }
        lastToken += 1
        let token = lastToken
        let task = Task { [weak self] in
            await self?.run(pack, token: token)
            return
        }
        jobs[pack.id] = Job(token: token, task: task)
        setDownload(pack.id, .running(0))
    }

    func cancel(_ packId: String) {
        guard let job = jobs.removeValue(forKey: packId) else { return }
        job.task.cancel()
        // The row goes back to "not downloading" at once; the job lets go of the network in its own time.
        if case .running? = downloads[packId] { setDownload(packId, nil) }
    }

    /// Forgets a failed download, so the pack is offered like any other again.
    func dismissFailure(_ packId: String) {
        if case .failed? = downloads[packId] { setDownload(packId, nil) }
    }

    private func run(_ pack: RemotePack, token: Int) async {
        var failure: DownloadError?
        var installed: CharacterPack?
        var calledOff = false

        await recovery.value
        await acquireSlot()
        if Task.isCancelled {
            // Called off while it waited for its turn.
            calledOff = true
        } else {
            // Called on the downloading thread; the row is touched on the main actor.
            let report: @Sendable (Float) -> Void = { [weak self] fraction in
                _ = Task { @MainActor [weak self] in
                    self?.publish(token, pack.id, fraction)
                }
            }
            do {
                try await installer.install(pack, onProgress: report)
                if Task.isCancelled {
                    // The cancellation landed while the pack was being put in place, and is only noticed now
                    // that it is there. The list has to show it, or the pack would sit on the phone unseen
                    // until the next start; but nobody is waiting to hear about it any more.
                    calledOff = true
                    await repository.refresh()
                } else {
                    let packs = await repository.refresh()
                    if Task.isCancelled {
                        // Called off while the list was being read: the pack is there and listed, but nobody
                        // is waiting to have it put on the stage.
                        calledOff = true
                    } else {
                        installed = packs.first { $0.id == pack.id && $0.isDownloaded }
                        if installed == nil { failure = .storage }
                    }
                }
            } catch let error as DownloadFailure {
                // A cancelled download can surface as a failed read; it is still a cancellation.
                if Task.isCancelled { calledOff = true } else { failure = error.error }
            } catch is CancellationError {
                calledOff = true
            } catch {
                failure = .storage
            }
        }
        releaseSlot()
        if calledOff { return }

        finish(token, pack.id, failure.map { DownloadState.failed($0) })
        // The pack was probably replaced on the server after this catalog was fetched. With a fresh one, trying
        // again asks for what is there now.
        if let failure, PackLibrary.staleCatalogSigns.contains(failure) {
            Task { [weak self] in await self?.refreshCatalog() }
        }
        if let installed {
            onEvent?(.installed(installed))
        } else if let failure {
            onEvent?(.failed(pack, failure))
        }
    }

    /// Shows the progress of the download that owns `packId`; progress only ever grows.
    private func publish(_ token: Int, _ packId: String, _ fraction: Float) {
        guard jobs[packId]?.token == token else { return }
        if case .running(let shown)? = downloads[packId], shown >= fraction { return }
        setDownload(packId, .running(fraction))
    }

    /// Ends the hold of a download on `packId`, leaving `state` behind (nothing when nil), unless it was called
    /// off or a newer download took over.
    private func finish(_ token: Int, _ packId: String, _ state: DownloadState?) {
        guard jobs[packId]?.token == token else { return }
        jobs[packId] = nil
        setDownload(packId, state)
    }

    private func setDownload(_ packId: String, _ state: DownloadState?) {
        downloads[packId] = state
        let running = downloads.values.contains { download in
            if case .running = download { return true }
            return false
        }
        if running != isDownloading { isDownloading = running }
    }

    // MARK: at most two at once

    private func acquireSlot() async {
        if activeDownloads < PackLibrary.maxParallelDownloads {
            activeDownloads += 1
            return
        }
        // The slot is handed over by `releaseSlot`, already counted.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            slotWaiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            activeDownloads -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }
}
