import Foundation

/// Struct that has time + related metadata
public struct AnnotatedTime: Sendable {

    /// Time that is being annotated
    public let date: Date

    /// Amount of time that has passed since the last NTP sync; in other words, the NTP response age.
    public let timeSinceLastNtpSync: TimeInterval

    /// Bound on the error of `date`, in seconds. It grows until the next synchronization.
    public let uncertainty: TimeInterval

    /// - parameter date:                  Time that is being annotated.
    /// - parameter timeSinceLastNtpSync:  Amount of time that has passed since the last NTP sync.
    /// - parameter uncertainty:           Bound on the error of `date`, in seconds.
    public init(date: Date, timeSinceLastNtpSync: TimeInterval, uncertainty: TimeInterval = 0) {
        self.date = date
        self.timeSinceLastNtpSync = timeSinceLastNtpSync
        self.uncertainty = uncertainty
    }
}

/// Symmetric key shared with the NTP servers, used for the message authentication code in RFC 5905
/// section 7.3.
///
/// When a key is configured, every request carries a MAC and any reply without a valid MAC for the same key
/// is discarded. Public pools such as `time.apple.com` do not have your key, so use this only with servers
/// you configure.
public struct NTPKey: Sendable {

    /// Digest algorithm the server uses for this key.
    public enum Algorithm: Sendable {
        /// MD5, the algorithm RFC 5905 defines. Supported by ntpd and chrony.
        case md5

        /// SHA-1. Supported by ntpd and chrony.
        case sha1
    }

    /// Key identifier, as configured on the server.
    public let id: UInt32

    /// Secret key bytes, as configured on the server.
    public let secret: Data

    /// Digest algorithm for this key.
    public let algorithm: Algorithm

    /// - parameter id:        Key identifier, as configured on the server.
    /// - parameter secret:    Secret key bytes, as configured on the server.
    /// - parameter algorithm: Digest algorithm for this key (default SHA-1).
    public init(id: UInt32, secret: Data, algorithm: Algorithm = .sha1) {
        self.id = id
        self.secret = secret
        self.algorithm = algorithm
    }
}

/// NTP pools to query, and how many samples to take from each resolved server.
public struct NTPConfiguration: Sendable {

    /// `time.apple.com`, four samples per resolved server.
    public static let standard = NTPConfiguration(
        pools: ["time.apple.com"],
        samples: 4
    )

    /// NTP pool hostnames. Each hostname is resolved into server addresses.
    public let pools: [String]

    /// Samples acquired from each resolved server.
    public let samples: Int

    /// Symmetric key for authenticated requests. `nil` sends unauthenticated requests.
    public let key: NTPKey?

    /// - parameter pools:   NTP pool hostnames. Each one is queried during the same synchronization.
    /// - parameter samples: Samples acquired from each resolved server (default 4).
    /// - parameter key:     Symmetric key shared with every server in `pools`. When set, replies without a
    ///                      valid MAC are discarded (default `nil`).
    public init(pools: [String], samples: Int = 4, key: NTPKey? = nil) {
        self.pools = pools
        self.samples = samples
        self.key = key
    }
}

/// One reply from an NTP server, before the replies are combined.
///
/// The clock filter keeps the lowest-delay reply from each server. A reply that sat in a queue has a large
/// round trip, and the offset computed from it can be wrong by about half of that extra delay.
public struct NTPMeasurement: Sendable, Equatable {

    /// Resolved server address.
    public let server: String

    /// Server stratum. 1 is a reference clock.
    public let stratum: Int

    /// Round-trip delay of this reply, in seconds.
    public let roundTripDelay: TimeInterval

    /// Clock offset of this reply, in seconds.
    public let offset: TimeInterval

    /// Dispersion of this reply, in seconds.
    public let dispersion: TimeInterval

    /// `true` when this is the lowest-delay reply from `server` in the clock filter's window.
    public let selected: Bool

    /// - parameter server:         Resolved server address.
    /// - parameter stratum:        Server stratum.
    /// - parameter roundTripDelay: Round-trip delay of this reply, in seconds.
    /// - parameter offset:         Clock offset of this reply, in seconds.
    /// - parameter dispersion:     Dispersion of this reply, in seconds.
    /// - parameter selected:       `true` when the clock filter keeps this reply for `server`.
    public init(server: String, stratum: Int, roundTripDelay: TimeInterval, offset: TimeInterval,
                dispersion: TimeInterval, selected: Bool)
    {
        self.server = server
        self.stratum = stratum
        self.roundTripDelay = roundTripDelay
        self.offset = offset
        self.dispersion = dispersion
        self.selected = selected
    }
}

extension NTPMeasurement {

    /// Replies in arrival order. `selected` is the earliest lowest-delay reply among the most recent
    /// filter stages for that server, which is the reply ``PeerEstimate`` keeps.
    static func collected(from samples: [(address: InternetAddress, packet: NTPPacket)]) -> [NTPMeasurement] {
        let floor = pow(2.0, Double(kLocalPrecision))
        var indicesByServer: [InternetAddress: [Int]] = [:]
        for (index, sample) in samples.enumerated() {
            indicesByServer[sample.address, default: []].append(index)
        }

        var selected: Set<Int> = []
        for indices in indicesByServer.values {
            let best = indices.suffix(kFilterStages).min { index, other in
                max(samples[index].packet.delay, floor) < max(samples[other].packet.delay, floor)
            }
            if let best = best {
                selected.insert(best)
            }
        }

        return samples.enumerated().map { index, sample in
            NTPMeasurement(server: sample.address.host ?? "unknown",
                           stratum: Int(sample.packet.stratumLevel),
                           roundTripDelay: sample.packet.delay,
                           offset: sample.packet.offset,
                           dispersion: sample.packet.dispersion,
                           selected: selected.contains(index))
        }
    }
}

/// One NTP sample that produced a usable clock adjustment.
public struct SyncSample: Sendable {

    /// Synchronized date after applying this sample.
    public let date: Date

    /// NTP offset for this sample, in seconds. This is the combined offset, not any single reply.
    public let offset: TimeInterval

    /// NTP operations finished so far, including this sample.
    public let completed: Int

    /// NTP operations scheduled for this synchronization.
    public let total: Int

    /// Valid replies received so far, in arrival order.
    public let measurements: [NTPMeasurement]

    /// `true` when this sample came from the last scheduled operation.
    ///
    /// Failed operations are not yielded, so a synchronization can finish with no sample where this is `true`.
    public var isLast: Bool {
        self.completed == self.total
    }

    /// - parameter date:         Synchronized date after applying this sample.
    /// - parameter offset:       Combined NTP offset for this sample, in seconds.
    /// - parameter completed:    NTP operations finished so far, including this sample.
    /// - parameter total:        NTP operations scheduled for this synchronization.
    /// - parameter measurements: Valid replies received so far, in arrival order.
    public init(date: Date, offset: TimeInterval, completed: Int, total: Int,
                measurements: [NTPMeasurement] = [])
    {
        self.date = date
        self.offset = offset
        self.completed = completed
        self.total = total
        self.measurements = measurements
    }
}

/// High level implementation for clock synchronization using NTP. All returned dates use the most accurate
/// synchronization and it's not affected by clock changes. Dates are extrapolated from a monotonic clock
/// that keeps counting while the device sleeps, corrected by the frequency error measured between
/// synchronizations, and stepped for leap seconds the servers announce. `now` is `nil` once the error
/// bound passes 1.5 seconds. A synchronization schedules another one 1024 seconds later, until `reset()`.
///
/// Example usage:
///
/// ```swift
/// Clock.sync { date, offset in
///     print(date)
/// }
/// // (... later on ...)
/// print(Clock.now)
///
/// let (date, offset) = await Clock.sync()
///
/// for await sample in Clock.syncing() {
///     print(sample.date)
/// }
///
/// let configuration = NTPConfiguration(pools: ["time.apple.com", "pool.ntp.org"], samples: 4)
/// Clock.sync(from: configuration)
/// ```
public struct Clock {
    private struct State {
        var stableTime: TimeFreeze?
        var pollTask: Task<Void, Never>?

        /// Bumped by `reset()`, so passes that started before it stop applying samples.
        var generation = 0
    }

    private static let state = Locked(State())

    /// Determines where the most current stable time is stored. Use TimeStoragePolicy.appGroup to share
    /// between your app and an extension.
    public static var storage = TimeStorage(storagePolicy: .standard)

    /// The most accurate timestamp that we have so far (nil if no synchronization was done yet)
    public static var timestamp: TimeInterval? {
        self.state.withLock { $0.stableTime }?.adjustedTimestamp()
    }

    /// The most accurate date that we have so far (nil if no synchronization was done yet, or the error
    /// bound has grown past 1.5 seconds)
    public static var now: Date? {
        self.annotatedNow?.date
    }

    /// Same as `now` except with analytic metadata about the time
    public static var annotatedNow: AnnotatedTime? {
        self.state.withLock { $0.stableTime }?.annotated()
    }

    /// Syncs the clock using NTP. Note that the full synchronization could take a few seconds. The given
    /// closure will be called with the first valid NTP response which accuracy should be good enough for the
    /// initial clock adjustment but it might not be the most accurate representation. After calling the
    /// closure this method will continue syncing with multiple servers and multiple passes.
    ///
    /// Both closures are called on the main thread.
    ///
    /// - parameter configuration: Pools to query and how many samples to take from each resolved server.
    ///                            Defaults to `time.apple.com` with 4 samples.
    /// - parameter completion:    A closure that will be called after _all_ the NTP calls are finished, or
    ///                            once `reset()` interrupts the synchronization.
    /// - parameter first:         A closure that will be called after the first valid date is calculated.
    public static func sync(from configuration: NTPConfiguration = .standard,
                            first: ((Date, TimeInterval) -> Void)? = nil,
                            completion: ((Date?, TimeInterval?) -> Void)? = nil)
    {
        let updates = self.query(configuration: configuration)
        Task { @MainActor in
            var reportedFirst = false
            var offset: TimeInterval?
            for await update in updates {
                offset = update.estimate?.offset
                if !reportedFirst, let offset = offset, let now = self.now {
                    reportedFirst = true
                    first?(now, offset)
                }
            }

            completion?(self.now, offset)
        }
    }

    /// Syncs the clock using NTP and suspends until every sample has finished.
    ///
    /// The returned date and offset are the last valid sample from ``syncing(from:)``. When no sample
    /// produces a date, both values are `nil`.
    ///
    /// - parameter configuration: Pools to query and how many samples to take from each resolved server.
    ///                            Defaults to `time.apple.com` with 4 samples.
    /// - returns: The latest synchronized date and its NTP offset, or `nil` values when synchronization
    ///            produces no usable sample.
    public static func sync(from configuration: NTPConfiguration = .standard) async
        -> (date: Date?, offset: TimeInterval?)
    {
        var latest: SyncSample?
        for await sample in self.syncing(from: configuration) { latest = sample }
        return (date: latest?.date, offset: latest?.offset)
    }

    /// Syncs the clock using NTP, yielding one element per valid sample.
    ///
    /// Each element is a usable adjustment, in the order the samples complete. The first element is the
    /// earliest date that can be used, including when the first network operation fails and a later sample
    /// succeeds. Later elements are finer adjustments as more servers respond. `measurements` lists every
    /// valid reply so far, including replies the clock filter did not keep. The stream finishes after
    /// every scheduled operation has completed, or once `reset()` interrupts the synchronization. Failed
    /// operations are not yielded.
    ///
    /// Creating the stream starts the synchronization. The full pass can take a few seconds, and it keeps
    /// running when the stream is not iterated to the end.
    ///
    /// - parameter configuration: Pools to query and how many samples to take from each resolved server.
    ///                            Defaults to `time.apple.com` with 4 samples.
    /// - returns: A stream of valid NTP samples. It is empty when synchronization produces none.
    public static func syncing(from configuration: NTPConfiguration = .standard) -> AsyncStream<SyncSample>
    {
        let updates = self.query(configuration: configuration)
        return AsyncStream { continuation in
            Task {
                for await update in updates {
                    if let offset = update.estimate?.offset, let date = self.now {
                        continuation.yield(SyncSample(date: date, offset: offset, completed: update.completed,
                                                      total: update.total, measurements: update.measurements))
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Starts one synchronization pass. Each NTP estimate is applied to the stable clock before it is
    /// yielded, and the last one schedules the next poll.
    ///
    /// The pass runs to the end whether or not the returned stream is iterated. `reset()` stops it.
    private static func query(configuration: NTPConfiguration) -> AsyncStream<NTPProgress> {
        let stored = self.storage.stableTime
        let generation: Int = self.state.withLock { state in
            state.stableTime = stored
            state.pollTask?.cancel()
            state.pollTask = nil
            return state.generation
        }

        // Every sample in this pass measures frequency against the clock as it was before the pass started.
        let previous = stored
        let (updates, continuation) = AsyncStream.makeStream(of: NTPProgress.self)

        Task {
            let responses = NTPClient().query(pools: configuration.pools, numberOfSamples: configuration.samples,
                                              key: configuration.key)
            for await update in responses {
                let isCurrent: Bool = self.state.withLock { state in
                    guard state.generation == generation else {
                        return false
                    }

                    if let estimate = update.estimate {
                        let freeze = TimeFreeze(offset: estimate.offset, leap: estimate.leap,
                                                rootDistance: estimate.rootDistance, previous: previous)
                        state.stableTime = freeze
                        self.storage.stableTime = freeze
                    }

                    if update.completed == update.total {
                        state.pollTask = self.schedulePoll(configuration: configuration)
                    }
                    return true
                }

                guard isCurrent else {
                    break
                }
                continuation.yield(update)
            }
            continuation.finish()
        }

        return updates
    }

    /// Synchronizes again after one poll interval, so the error bound stays usable and frequency can be
    /// measured. `reset()` cancels it.
    private static func schedulePoll(configuration: NTPConfiguration) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(kPollInterval * 1_000_000_000))
            if !Task.isCancelled {
                _ = self.query(configuration: configuration)
            }
        }
    }

    /// Resets all state of the monotonic clock and stops any synchronization in progress. Note that you
    /// won't be able to access `now` until you `sync` again.
    public static func reset() {
        self.state.withLock { state in
            state.pollTask?.cancel()
            state.pollTask = nil
            state.stableTime = nil
            state.generation += 1
        }
    }
}
