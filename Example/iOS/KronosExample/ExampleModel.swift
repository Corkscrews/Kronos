import Combine
import Foundation
import Kronos

/// Pools offered by the example. Choosing one starts a synchronization against that host.
enum NTPPool: String, CaseIterable, Identifiable {
    case apple = "time.apple.com"
    case nist = "time.nist.gov"
    case galway = "ntp-galway.hea.net"
    case netherlands = "ntppool3.time.nl"

    var id: String { self.rawValue }
    var hostname: String { self.rawValue }
}

/// Same loop as the terminal example: Sync starts an NTP pass, and the screen keeps reading `Clock.now`.
@MainActor
final class ExampleModel: ObservableObject {
    private enum SyncStatus {
        case idle
        case syncing
        case failed
    }

    private struct SyncProgress {
        var offset: TimeInterval?
        var completed = 0
        var total = 0
        var measurements: [NTPMeasurement] = []

        static let empty = SyncProgress(offset: nil)
    }

    @Published private(set) var pool: NTPPool = .apple
    @Published private var status: SyncStatus = .idle
    @Published private var progress = SyncProgress.empty

    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0

    var isSyncing: Bool { self.status == .syncing }
    var didFail: Bool { self.status == .failed }
    var offset: TimeInterval? { self.progress.offset }
    var completed: Int { self.progress.completed }
    var total: Int { self.progress.total }
    var measurements: [NTPMeasurement] { self.progress.measurements }

    /// Switches the pool and starts a new synchronization, replacing one already in progress.
    func select(_ pool: NTPPool) {
        guard pool != self.pool else {
            return
        }
        self.pool = pool
        self.beginSync(replacingCurrent: true)
    }

    func sync() {
        self.beginSync(replacingCurrent: false)
    }

    func reset() {
        self.syncTask?.cancel()
        self.syncTask = nil
        self.syncGeneration += 1
        Clock.reset()
        self.status = .idle
        self.progress = .empty
    }

    private func beginSync(replacingCurrent: Bool) {
        if self.isSyncing, !replacingCurrent {
            return
        }

        self.syncTask?.cancel()
        if replacingCurrent {
            Clock.reset()
        }

        self.status = .syncing
        self.progress = .empty
        self.syncGeneration += 1

        let generation = self.syncGeneration
        let updates = Clock.syncing(from: NTPConfiguration(pools: [self.pool.hostname]))
        self.syncTask = Task { [weak self] in
            await self?.runSync(updates: updates, generation: generation)
        }
    }

    private func runSync(updates: AsyncStream<SyncSample>, generation: Int) async {
        var receivedSample = false
        for await sample in updates {
            if Task.isCancelled || self.syncGeneration != generation {
                return
            }
            receivedSample = true
            self.progress = SyncProgress(
                offset: sample.offset,
                completed: sample.completed,
                total: sample.total,
                measurements: sample.measurements
            )
        }

        guard !Task.isCancelled, self.syncGeneration == generation else {
            return
        }

        self.status = receivedSample ? .idle : .failed
        self.syncTask = nil
    }
}
