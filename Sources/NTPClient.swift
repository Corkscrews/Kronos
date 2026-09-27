import Foundation

private let kDefaultTimeout = 6.0
private let kDefaultSamples = 4
private let kMaximumNTPServers = 5

/// RFC 5905 burst mode spaces packets to the same server 2 seconds apart.
private let kMinimumSampleSpacing = 2.0

/// Clock filter stages kept per server (RFC 5905 NSTAGE).
let kFilterStages = 8

/// Floor on the root delay used for root distance, in seconds (RFC 5905 MINDISP).
private let kMinimumDispersion = 0.005

/// The cluster algorithm stops pruning at this many survivors (RFC 5905 NMIN).
private let kMinimumClusterSurvivors = 3

/// Shortest hold after a RATE kiss-o'-death, in seconds (RFC 5905 MINPOLL of 2^6).
private let kMinimumRateHold = 64.0

/// Exception raised while sending / receiving NTP packets.
enum NTPNetworkError: Error {
    case noValidNTPPacketFound
}

/// System offset and leap indicator from the servers that survived selection.
struct NTPEstimate {

    /// Combined clock offset in seconds.
    let offset: TimeInterval

    /// Leap indicator of the system peer, the best server after clustering.
    let leap: LeapIndicator

    /// Root distance of the system peer, in seconds. The local error bound starts here and grows with time.
    let rootDistance: TimeInterval
}

/// Servers that sent a kiss-o'-death. Shared by every client in the process, on the main actor.
@MainActor
enum KissOfDeathRegistry {
    private static var denied: Set<InternetAddress> = []
    private static var holds: [InternetAddress: TimeInterval] = [:]

    /// Records a kiss code from `address`. DENY and RSTR block the server for the life of the process. RATE
    /// blocks it for the poll interval the server asked for, and never less than 64 seconds.
    static func record(_ code: KissCode, from address: InternetAddress, poll: Int8) {
        switch code {
        case .deny, .restricted:
            self.denied.insert(address)

        case .rateExceeded:
            let hold = max(kMinimumRateHold, pow(2.0, Double(min(max(poll, 0), 17))))
            self.holds[address] = TimeFreeze.systemUptime() + hold

        case .other:
            break
        }
    }

    /// `true` when `address` sent DENY or RSTR, or sent RATE and its hold has not expired.
    static func isBlocked(_ address: InternetAddress) -> Bool {
        if self.denied.contains(address) {
            return true
        }

        guard let until = self.holds[address] else {
            return false
        }

        if TimeFreeze.systemUptime() < until {
            return true
        }

        self.holds[address] = nil
        return false
    }

    /// Forgets every recorded kiss code.
    static func reset() {
        self.denied = []
        self.holds = [:]
    }
}

/// Progress of a pool query after one more sample finished.
struct NTPProgress {

    /// Estimate from every response received so far. `nil` when no server survives selection yet.
    let estimate: NTPEstimate?

    /// Samples finished so far, including skipped ones.
    let completed: Int

    /// Samples scheduled for this query.
    let total: Int

    /// Valid replies so far, in arrival order. `selected` is the reply the clock filter kept.
    let measurements: [NTPMeasurement]
}

/// Outcome of one request/reply exchange with a server.
struct NTPSampleResult {

    /// The valid reply, or `nil` when the exchange failed.
    let packet: NTPPacket?

    /// `true` when the server is blocked by a kiss-o'-death, so the remaining samples are skipped.
    let blocked: Bool
}

/// One finished sample within a server's burst.
private struct BurstSample {
    let address: InternetAddress
    let result: NTPSampleResult
    let remaining: Int
    let startTime: TimeInterval
}

/// NTP client session.
final class NTPClient: Sendable {

    /// Query the addresses that resolve from the given pools.
    ///
    /// Each pool is resolved on its own. Up to `maximumServers` addresses are taken from each pool, and the
    /// same address is queried only once when pools overlap. Servers that sent a kiss-o'-death are skipped.
    /// Samples from every selected server contribute to one shared estimate.
    ///
    /// Ending iteration early cancels the query.
    ///
    /// - parameter pools:           NTP pools that will be resolved into NTP servers.
    /// - parameter port:            Server NTP port (default 123).
    /// - parameter version:         NTP version to send. RFC 5905 uses version 4.
    /// - parameter numberOfSamples: The number of samples to be acquired from each server (default 4).
    /// - parameter maximumServers:  The maximum number of servers to be queried from each pool (default 5).
    /// - parameter key:             Symmetric key for authenticated requests (default `nil`).
    /// - parameter timeout:         The individual timeout for each of the NTP operations.
    /// - returns: One element as each sample finishes. A single element with a total of 0 means no server
    ///            could be queried.
    func query(pools: [String] = ["time.apple.com"], version: Int8 = 4, port: Int = 123,
               numberOfSamples: Int = kDefaultSamples, maximumServers: Int = kMaximumNTPServers,
               key: NTPKey? = nil, timeout: TimeInterval = kDefaultTimeout) -> AsyncStream<NTPProgress>
    {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                let hosts = self.uniqueHosts(in: pools)
                let selected = self.servers(from: await self.resolve(hosts), maximumServers: maximumServers)
                if selected.isEmpty || numberOfSamples < 1 {
                    continuation.yield(NTPProgress(estimate: nil, completed: 0, total: 0, measurements: []))
                } else {
                    await self.query(addresses: selected, port: port, version: version, key: key,
                                     timeout: timeout, numberOfSamples: numberOfSamples,
                                     progress: continuation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Query each resolved server and report a single estimate computed from every response received so far.
    ///
    /// Samples to the same server are spaced at least 2 seconds apart. A kiss-o'-death reply skips that
    /// server's remaining samples, which count as finished.
    @MainActor
    private func query(addresses: [InternetAddress], port: Int, version: Int8, key: NTPKey?,
                       timeout: TimeInterval, numberOfSamples: Int,
                       progress: AsyncStream<NTPProgress>.Continuation) async
    {
        var servers: [InternetAddress: [NTPPacket]] = [:]
        var received: [(address: InternetAddress, packet: NTPPacket)] = []
        var completed = 0
        let total = addresses.count * numberOfSamples

        await withTaskGroup(of: BurstSample.self) { group in
            func schedule(_ address: InternetAddress, remaining: Int, notBefore: TimeInterval) {
                group.addTask {
                    let wait = notBefore - currentTime()
                    if wait > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    }

                    let startTime = currentTime()
                    let result = await self.sample(ip: address, port: port, version: version, key: key,
                                                   timeout: timeout)
                    return BurstSample(address: address, result: result, remaining: remaining - 1,
                                       startTime: startTime)
                }
            }

            for address in addresses {
                schedule(address, remaining: numberOfSamples, notBefore: 0)
            }

            for await sample in group {
                if let packet = sample.result.packet {
                    servers[sample.address, default: []].append(packet)
                    received.append((address: sample.address, packet: packet))
                }

                completed += 1 + (sample.result.blocked ? sample.remaining : 0)
                let estimate = NTPClient.estimate(from: Array(servers.values), now: currentTime())
                let measurements = NTPMeasurement.collected(from: received)
                progress.yield(NTPProgress(estimate: estimate, completed: completed, total: total,
                                           measurements: measurements))

                if !sample.result.blocked && sample.remaining > 0 && !Task.isCancelled {
                    schedule(sample.address, remaining: sample.remaining,
                             notBefore: sample.startTime + kMinimumSampleSpacing)
                }
            }
        }
    }

    /// Sends one request to the given NTP server and waits for its reply.
    ///
    /// - parameter ip:      Server socket address.
    /// - parameter port:    Server NTP port (default 123).
    /// - parameter version: NTP version to send. RFC 5905 uses version 4.
    /// - parameter key:     Symmetric key. When set, replies without a valid MAC are discarded.
    /// - parameter timeout: Timeout on socket operations.
    /// - returns: The reply when it is valid, and whether the server is now blocked by a kiss-o'-death.
    @MainActor
    func sample(ip: InternetAddress, port: Int = 123, version: Int8 = 4, key: NTPKey? = nil,
                timeout: TimeInterval = kDefaultTimeout) async -> NTPSampleResult
    {
        if KissOfDeathRegistry.isBlocked(ip) {
            return NTPSampleResult(packet: nil, blocked: true)
        }

        let exchange = NTPExchange(version: version, key: key)
        let (data, destinationTime) = await exchange.run(to: ip, port: port, timeout: timeout)
        let PDU = data.flatMap { data -> NTPPacket? in
            guard key.map({ NTPPacket.isAuthentic(data, key: $0) }) ?? true else {
                return nil
            }
            return try? NTPPacket(data: data, destinationTime: destinationTime)
        }

        // Only a kiss that answers this request counts; anyone can send a forged one.
        if let PDU = PDU, PDU.originTimestamp == exchange.transmitTimestamp, let code = PDU.kissCode {
            KissOfDeathRegistry.record(code, from: ip, poll: PDU.poll)
            if KissOfDeathRegistry.isBlocked(ip) {
                return NTPSampleResult(packet: nil, blocked: true)
            }
        }

        guard let PDU = PDU, PDU.isValidResponse(matching: exchange.transmitTimestamp) else {
            return NTPSampleResult(packet: nil, blocked: false)
        }
        return NTPSampleResult(packet: PDU, blocked: false)
    }

    /// Resolves every host at the same time, keeping the input order.
    @MainActor
    private func resolve(_ hosts: [String]) async -> [[InternetAddress]] {
        await withTaskGroup(of: (Int, [InternetAddress]).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask { (index, await DNSResolver.resolve(host: host)) }
            }

            var resolved: [[InternetAddress]] = Array(repeating: [], count: hosts.count)
            for await (index, addresses) in group {
                resolved[index] = addresses
            }
            return resolved
        }
    }

    /// Hostnames in first-seen order, without blanks or repeats.
    private func uniqueHosts(in pools: [String]) -> [String] {
        var seen: Set<String> = []
        var hosts: [String] = []
        for pool in pools {
            if pool.isEmpty || seen.contains(pool) {
                continue
            }
            seen.insert(pool)
            hosts.append(pool)
        }
        return hosts
    }

    /// Up to `maximumServers` unique addresses from each resolved pool, in pool order, skipping servers that
    /// sent a kiss-o'-death.
    @MainActor
    private func servers(from resolvedPools: [[InternetAddress]], maximumServers: Int) -> [InternetAddress] {
        var selected: [InternetAddress] = []
        var seen: Set<InternetAddress> = []
        for addresses in resolvedPools {
            var taken = 0
            for address in addresses {
                if taken >= maximumServers {
                    break
                }
                if !KissOfDeathRegistry.isBlocked(address) && seen.insert(address).inserted {
                    selected.append(address)
                    taken += 1
                }
            }
        }
        return selected
    }

    // MARK: - NTP Calculation (RFC 5905 sections 10 and 11)

    /// Runs the clock filter on each server's samples, then the selection, cluster and combine algorithms.
    ///
    /// - parameter responses: Valid samples, grouped by server, oldest first.
    /// - parameter now:       Current time, used to age each sample's dispersion.
    /// - returns: The combined estimate, or `nil` when no majority of servers agree.
    static func estimate(from responses: [[NTPPacket]], now: TimeInterval) -> NTPEstimate? {
        let peers = responses.compactMap { PeerEstimate(samples: $0, now: now) }
        let survivors = self.cluster(self.select(peers))
        guard let systemPeer = survivors.first else {
            return nil
        }

        return NTPEstimate(offset: self.combine(survivors), leap: systemPeer.leap,
                           rootDistance: systemPeer.rootDistance)
    }

    /// Selection algorithm (RFC 5905 section 11.2.1). Finds the smallest interval that contains the
    /// correctness intervals of a majority of servers, and drops servers whose offset falls outside it.
    ///
    /// - parameter peers: Filtered estimates, one per server.
    /// - returns: The truechimers, or an empty array when no majority agree.
    static func select(_ peers: [PeerEstimate]) -> [PeerEstimate] {
        let candidates = peers.filter { $0.rootDistance < kMaximumDistance }
        let count = candidates.count
        guard count > 0 else {
            return []
        }

        // Each server contributes a low edge (-1), its offset (0) and a high edge (+1).
        var edges: [(value: TimeInterval, type: Int)] = []
        for peer in candidates {
            edges.append((peer.offset - peer.rootDistance, -1))
            edges.append((peer.offset, 0))
            edges.append((peer.offset + peer.rootDistance, 1))
        }
        edges.sort { $0.value < $1.value || ($0.value == $1.value && $0.type < $1.type) }

        var allowed = 0
        while 2 * allowed < count {
            var found = 0
            var chime = 0
            var low = TimeInterval.infinity
            for edge in edges {
                chime -= edge.type
                if chime >= count - allowed {
                    low = edge.value
                    break
                }
                if edge.type == 0 {
                    found += 1
                }
            }

            chime = 0
            var high = -TimeInterval.infinity
            for edge in edges.reversed() {
                chime += edge.type
                if chime >= count - allowed {
                    high = edge.value
                    break
                }
                if edge.type == 0 {
                    found += 1
                }
            }

            if found <= allowed && low < high {
                return candidates.filter { $0.offset >= low && $0.offset <= high }
            }
            allowed += 1
        }

        return []
    }

    /// Cluster algorithm (RFC 5905 section 11.2.2). Repeatedly drops the server that adds the most
    /// selection jitter, until that jitter is below the best server's own jitter or few servers remain.
    ///
    /// - parameter survivors: Truechimers from the selection algorithm.
    /// - returns: Survivors ordered by merit, best first.
    static func cluster(_ survivors: [PeerEstimate]) -> [PeerEstimate] {
        var survivors = survivors.sorted { $0.merit < $1.merit }
        while survivors.count > kMinimumClusterSurvivors {
            var worst = 0
            var worstJitter = -1.0
            for (index, peer) in survivors.enumerated() {
                let squares = survivors.reduce(0.0) { $0 + pow(peer.offset - $1.offset, 2) }
                let jitter = sqrt(squares / Double(survivors.count - 1))
                if jitter > worstJitter {
                    worst = index
                    worstJitter = jitter
                }
            }

            let bestPeerJitter = survivors.map { $0.jitter }.min() ?? 0
            if worstJitter < bestPeerJitter {
                break
            }
            survivors.remove(at: worst)
        }

        return survivors
    }

    /// Combine algorithm (RFC 5905 section 11.2.3). Averages the survivors' offsets, each weighted by the
    /// inverse of its root distance.
    static func combine(_ survivors: [PeerEstimate]) -> TimeInterval {
        var weights = 0.0
        var total = 0.0
        for peer in survivors {
            let weight = 1 / peer.rootDistance
            weights += weight
            total += weight * peer.offset
        }
        return total / weights
    }

    // MARK: - Private helpers (CFSocket)

    /// Reads one datagram and the kernel's receive timestamp.
    ///
    /// - parameter socket: A UDP socket with `SO_TIMESTAMP` enabled.
    /// - returns: The datagram (`nil` on error) and its arrival time. The arrival time falls back to the
    ///            current time when the kernel did not attach a timestamp.
    fileprivate static func receive(from socket: CFSocketNativeHandle) -> (Data?, TimeInterval) {
        var buffer = [UInt8](repeating: 0, count: 1024)
        var control = [UInt8](repeating: 0, count: 64)
        var controlLength = 0

        let count: Int = buffer.withUnsafeMutableBytes { bufferPointer in
            control.withUnsafeMutableBytes { controlPointer in
                var vector = iovec(iov_base: bufferPointer.baseAddress, iov_len: bufferPointer.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                         msg_control: controlPointer.baseAddress,
                                         msg_controllen: socklen_t(controlPointer.count), msg_flags: 0)
                    let received = recvmsg(socket, &message, 0)
                    controlLength = Int(message.msg_controllen)
                    return received
                }
            }
        }

        let fallback = currentTime()
        guard count > 0 else {
            return (nil, fallback)
        }

        let arrival = self.receiveTimestamp(fromControl: Array(control.prefix(controlLength)))
        return (Data(buffer.prefix(count)), arrival ?? fallback)
    }

    /// Finds the `SCM_TIMESTAMP` control message and returns its time.
    ///
    /// - parameter control: The ancillary data from `recvmsg`.
    /// - returns: The receive time in EPOCH format, or `nil` when there is no timestamp.
    static func receiveTimestamp(fromControl control: [UInt8]) -> TimeInterval? {
        // Darwin aligns control messages and their data to 4 bytes (__DARWIN_ALIGN32).
        func align(_ length: Int) -> Int {
            (length + 3) & ~3
        }

        let headerLength = MemoryLayout<cmsghdr>.size
        var offset = 0
        while offset + headerLength <= control.count {
            var header = cmsghdr()
            withUnsafeMutableBytes(of: &header) { $0.copyBytes(from: control[offset ..< offset + headerLength]) }

            let length = Int(header.cmsg_len)
            if length < headerLength || offset + length > control.count {
                return nil
            }

            let dataOffset = offset + align(headerLength)
            if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_TIMESTAMP
                && offset + length - dataOffset >= MemoryLayout<timeval>.size
            {
                var time = timeval()
                withUnsafeMutableBytes(of: &time) {
                    $0.copyBytes(from: control[dataOffset ..< dataOffset + MemoryLayout<timeval>.size])
                }
                return Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
            }

            offset += align(length)
        }

        return nil
    }
}

/// One NTP request and its reply, on a UDP socket scheduled on the main run loop.
@MainActor
private final class NTPExchange {
    private let version: Int8
    private let key: NTPKey?
    private var socket: CFSocket?
    private var source: CFRunLoopSource?
    private var continuation: CheckedContinuation<(Data?, TimeInterval), Never>?
    private var timeout: Task<Void, Never>?

    /// Wire transmit timestamp of the request, used to match the reply. 0 until the request is sent.
    private(set) var transmitTimestamp: UInt64 = 0

    init(version: Int8, key: NTPKey?) {
        self.version = version
        self.key = key
    }

    /// Sends the request and waits for one datagram.
    ///
    /// - returns: The reply (`nil` on error, timeout or cancellation) and its arrival time. The arrival time
    ///            is infinite when there is no reply.
    func run(to ip: InternetAddress, port: Int, timeout: TimeInterval) async -> (Data?, TimeInterval) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.start(to: ip, port: port, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil, .infinity) }
        }
    }

    private func start(to ip: InternetAddress, port: Int, timeout: TimeInterval,
                       continuation: CheckedContinuation<(Data?, TimeInterval), Never>)
    {
        self.continuation = continuation

        let callback: CFSocketCallBack = { _, callbackType, _, _, info in
            guard let info = info else {
                return
            }

            let exchange = Unmanaged<NTPExchange>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { exchange.handle(callbackType) }
        }

        // `run` keeps the exchange alive until `finish` invalidates the socket.
        let types = CFSocketCallBackType.readCallBack.rawValue | CFSocketCallBackType.writeCallBack.rawValue
        var socketContext = CFSocketContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let socket = CFSocketCreate(nil, ip.family, SOCK_DGRAM, IPPROTO_UDP, types, callback, &socketContext),
            CFSocketIsValid(socket) else
        {
            self.finish(nil, .infinity)
            return
        }

        let native = CFSocketGetNative(socket)
        // Ask the kernel to stamp each datagram on arrival, so T4 excludes run loop scheduling delay.
        var enabled: Int32 = 1
        setsockopt(native, SOL_SOCKET, SO_TIMESTAMP, &enabled, socklen_t(MemoryLayout<Int32>.size))
        // Drop the write on a closed socket instead of raising SIGPIPE for the whole process.
        var noSignal: Int32 = 1
        setsockopt(native, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        self.socket = socket
        self.source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), self.source, CFRunLoopMode.commonModes)
        CFSocketConnectToAddress(socket, ip.addressData(withPort: port), timeout)

        self.timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            self?.finish(nil, .infinity)
        }
    }

    private func handle(_ callbackType: CFSocketCallBackType) {
        guard let socket = self.socket else {
            return
        }

        if callbackType == .writeCallBack {
            var packet = NTPPacket(version: self.version)
            let PDU = packet.prepareToSend(key: self.key) as CFData
            self.transmitTimestamp = packet.transmitTimestamp
            CFSocketSendData(socket, nil, PDU, kDefaultTimeout)
            return
        }

        let (response, destinationTime) = NTPClient.receive(from: CFSocketGetNative(socket))
        self.finish(response, destinationTime)
    }

    /// Closes the socket and returns the reply. Only the first call has an effect.
    private func finish(_ data: Data?, _ destinationTime: TimeInterval) {
        guard let continuation = self.continuation else {
            return
        }

        self.continuation = nil
        self.timeout?.cancel()
        if let socket = self.socket {
            CFSocketInvalidate(socket)
        }
        if let source = self.source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }
        self.socket = nil
        self.source = nil
        continuation.resume(returning: (data, destinationTime))
    }
}

/// One server's statistics after the clock filter (RFC 5905 section 10).
struct PeerEstimate {

    /// Offset of the lowest-delay sample, in seconds.
    let offset: TimeInterval

    /// Round-trip delay of the lowest-delay sample, in seconds.
    let delay: TimeInterval

    /// Filter dispersion: sample dispersions, aged since arrival and weighted by 1/2 per delay rank.
    let dispersion: TimeInterval

    /// RMS difference between the best sample's offset and the other samples' offsets, in seconds.
    let jitter: TimeInterval

    /// Server's root delay, in seconds.
    let rootDelay: TimeInterval

    /// Server's root dispersion, in seconds.
    let rootDispersion: TimeInterval

    /// Server's stratum.
    let stratum: Int

    /// Server's leap indicator.
    let leap: LeapIndicator

    /// Maximum error of this server's offset: half the round trip to the reference clock plus every
    /// dispersion and jitter term (RFC 5905 section 11.2).
    var rootDistance: TimeInterval {
        max(kMinimumDispersion, self.rootDelay + self.delay) / 2 + self.rootDispersion
            + self.dispersion + self.jitter
    }

    /// Ordering for the cluster algorithm. Lower stratum wins, then lower root distance.
    var merit: TimeInterval {
        Double(self.stratum) * kMaximumDistance + self.rootDistance
    }

    /// Runs the clock filter on one server's samples.
    ///
    /// Uses up to the 8 most recent samples. RFC 5905 fills empty filter stages with the maximum
    /// dispersion, which suits a long-running association. A single burst would then need eight replies
    /// before any server is selectable, so empty stages are left out instead.
    ///
    /// - parameter samples: Valid samples from one server, oldest first.
    /// - parameter now:     Current time, used to age each sample's dispersion.
    init?(samples: [NTPPacket], now: TimeInterval) {
        let localPrecision = pow(2.0, Double(kLocalPrecision))
        let recent = samples.suffix(kFilterStages).sorted {
            max($0.delay, localPrecision) < max($1.delay, localPrecision)
        }
        guard let best = recent.first else {
            return nil
        }

        var dispersion = 0.0
        for (index, sample) in recent.enumerated() {
            let aged = sample.dispersion + kFrequencyTolerance * max(0, now - sample.destinationTime)
            dispersion += aged / pow(2.0, Double(index + 1))
        }

        var jitter = 0.0
        if recent.count > 1 {
            let squares = recent.dropFirst().reduce(0.0) { $0 + pow($1.offset - best.offset, 2) }
            jitter = sqrt(squares / Double(recent.count - 1))
        }

        self.offset = best.offset
        self.delay = max(best.delay, localPrecision)
        self.dispersion = dispersion
        self.jitter = max(jitter, localPrecision)
        self.rootDelay = best.rootDelay
        self.rootDispersion = best.rootDispersion
        self.stratum = Int(best.stratumLevel)
        self.leap = best.leap
    }

    init(offset: TimeInterval, delay: TimeInterval, dispersion: TimeInterval, jitter: TimeInterval,
         rootDelay: TimeInterval, rootDispersion: TimeInterval, stratum: Int, leap: LeapIndicator)
    {
        self.offset = offset
        self.delay = delay
        self.dispersion = dispersion
        self.jitter = jitter
        self.rootDelay = rootDelay
        self.rootDispersion = rootDispersion
        self.stratum = stratum
        self.leap = leap
    }
}
