@testable import Kronos
import XCTest

final class NTPClientTests: XCTestCase {

    func testQueryIP() async {
        let addresses = await DNSResolver.resolve(host: "time.apple.com")
        XCTAssertGreaterThan(addresses.count, 0)

        let result = await NTPClient().sample(ip: addresses.first!, version: 3)
        XCTAssertFalse(result.blocked)
        XCTAssertNotNil(result.packet)
        XCTAssertGreaterThanOrEqual(result.packet!.version, 3)
        XCTAssertTrue(result.packet!.isValidResponse())
    }

    func testQueryPool() async {
        let offset = await self.lastEstimate(pools: ["0.pool.ntp.org"])
        XCTAssertNotNil(offset)

        let offset2 = await self.lastEstimate(pools: ["0.pool.ntp.org"])
        XCTAssertNotNil(offset2)
        XCTAssertLessThan(abs(offset!.offset - offset2!.offset), 0.10)
    }

    func testQueryPoolWithIPv6() async {
        let offset = await self.lastEstimate(pools: ["2.pool.ntp.org"])
        XCTAssertNotNil(offset)
    }

    func testQueryReportsProgressUntilTotal() async {
        var updates: [NTPProgress] = []
        for await update in NTPClient().query(pools: ["time.apple.com"], numberOfSamples: 2, maximumServers: 1) {
            updates.append(update)
        }

        XCTAssertEqual(updates.map(\.completed), [1, 2])
        XCTAssertEqual(updates.last?.total, 2)
    }

    func testQueryWithoutServersFinishesEmpty() async {
        var updates: [NTPProgress] = []
        for await update in NTPClient().query(pools: [""]) {
            updates.append(update)
        }

        XCTAssertEqual(updates.count, 1)
        XCTAssertNil(updates.first?.estimate)
        XCTAssertEqual(updates.first?.total, 0)
    }

    // MARK: - Selection, cluster and combine

    func testSelectionDropsFalseticker() {
        let truechimers = [0.010, 0.012, 0.011].map { peer(offset: $0, distance: 0.02) }
        let falseticker = peer(offset: 5.0, distance: 0.02)

        let survivors = NTPClient.select(truechimers + [falseticker])
        XCTAssertEqual(survivors.map { $0.offset }.sorted(), [0.010, 0.011, 0.012])
    }

    func testSelectionFailsWithoutMajority() {
        let peers = [peer(offset: 0, distance: 0.01), peer(offset: 1, distance: 0.01)]
        XCTAssertTrue(NTPClient.select(peers).isEmpty)
    }

    func testSelectionRejectsDistantServers() {
        XCTAssertTrue(NTPClient.select([peer(offset: 0, distance: 2)]).isEmpty)
    }

    func testClusterPrunesOutlierDownToMinimum() {
        let peers = [0.0, 0.001, 0.002, 0.003, 0.05].map { peer(offset: $0, distance: 0.1, jitter: 0.0001) }
        let survivors = NTPClient.cluster(peers)
        XCTAssertEqual(survivors.count, 3)
        XCTAssertFalse(survivors.contains { $0.offset == 0.05 })
    }

    func testCombineWeightsByRootDistance() {
        let near = peer(offset: 0.0, distance: 0.01)
        let far = peer(offset: 0.3, distance: 0.02)
        XCTAssertEqual(NTPClient.combine([near, far]), 0.1, accuracy: 1e-9)
    }

    func testEstimateUsesSystemPeerLeap() {
        let leaping = peer(offset: 0.0, distance: 0.01, stratum: 1, leap: .sixtyOneSeconds)
        let other = peer(offset: 0.001, distance: 0.01, stratum: 2, leap: .noWarning)
        XCTAssertEqual(NTPClient.cluster([other, leaping]).first?.leap, .sixtyOneSeconds)
    }

    func testMeasurementsExposeLowestDelaySample() {
        let now = currentTime()
        let first = address("192.0.2.10")
        let second = address("192.0.2.11")
        let samples = [
            (address: first, packet: reply(now: now, offset: 0.200, delay: 0.410)),
            (address: first, packet: reply(now: now, offset: 0.013, delay: 0.035)),
            (address: first, packet: reply(now: now, offset: 0.015, delay: 0.038)),
            (address: second, packet: reply(now: now, offset: 0.040, delay: 0.090)),
            (address: second, packet: reply(now: now, offset: 0.011, delay: 0.030)),
        ]

        let measurements = NTPMeasurement.collected(from: samples)

        XCTAssertEqual(measurements.map(\.server), [
            "192.0.2.10", "192.0.2.10", "192.0.2.10", "192.0.2.11", "192.0.2.11",
        ])
        XCTAssertEqual(measurements.map(\.stratum), [2, 2, 2, 2, 2])
        XCTAssertEqual(measurements.map(\.selected), [false, true, false, false, true])
        XCTAssertEqual(measurements[0].offset, 0.200, accuracy: 1e-4)
        XCTAssertEqual(measurements[0].roundTripDelay, 0.410, accuracy: 1e-4)
        XCTAssertEqual(measurements[1].offset, 0.013, accuracy: 1e-4)
        XCTAssertEqual(measurements[1].roundTripDelay, 0.035, accuracy: 1e-4)
        XCTAssertGreaterThan(measurements[0].dispersion, 0)
    }

    func testClockFilterPicksLowestDelay() {
        let now = currentTime()
        let samples = [
            reply(now: now, offset: 0.5, delay: 0.2),
            reply(now: now, offset: 0.1, delay: 0.02),
            reply(now: now, offset: 0.3, delay: 0.1),
        ]

        let estimate = PeerEstimate(samples: samples, now: now)!
        XCTAssertEqual(estimate.offset, 0.1, accuracy: 1e-6)
        XCTAssertEqual(estimate.delay, 0.02, accuracy: 1e-6)
        XCTAssertGreaterThan(estimate.jitter, 0.2)
    }

    // MARK: - Kiss-o'-death

    @MainActor
    func testKissOfDeathBlocksServer() {
        KissOfDeathRegistry.reset()
        defer { KissOfDeathRegistry.reset() }

        let denied = address("192.0.2.1")
        let limited = address("192.0.2.2")
        let other = address("192.0.2.3")
        KissOfDeathRegistry.record(.deny, from: denied, poll: 4)
        KissOfDeathRegistry.record(.rateExceeded, from: limited, poll: 4)
        KissOfDeathRegistry.record(.other(0x41435354), from: other, poll: 4)

        XCTAssertTrue(KissOfDeathRegistry.isBlocked(denied))
        XCTAssertTrue(KissOfDeathRegistry.isBlocked(limited))
        XCTAssertFalse(KissOfDeathRegistry.isBlocked(other))
    }

    @MainActor
    func testBlockedServerIsSkippedWithoutSending() async {
        KissOfDeathRegistry.reset()
        defer { KissOfDeathRegistry.reset() }

        let denied = address("192.0.2.1")
        KissOfDeathRegistry.record(.restricted, from: denied, poll: 4)

        let result = await NTPClient().sample(ip: denied)
        XCTAssertNil(result.packet)
        XCTAssertTrue(result.blocked)
    }

    @MainActor
    func testBlockedServerIsNotSelected() async {
        KissOfDeathRegistry.reset()
        defer { KissOfDeathRegistry.reset() }

        KissOfDeathRegistry.record(.deny, from: address("192.0.2.1"), poll: 4)

        var totals: [Int] = []
        for await update in NTPClient().query(pools: ["192.0.2.1"]) {
            totals.append(update.total)
        }
        XCTAssertEqual(totals, [0])
    }

    // MARK: - Kernel receive timestamps

    func testReadsKernelReceiveTimestamp() {
        let headerLength = MemoryLayout<cmsghdr>.size
        var header = cmsghdr(cmsg_len: socklen_t(headerLength + MemoryLayout<timeval>.size),
                             cmsg_level: SOL_SOCKET, cmsg_type: SCM_TIMESTAMP)
        var time = timeval(tv_sec: 1_700_000_000, tv_usec: 250_000)

        var control = [UInt8](repeating: 0, count: 64)
        withUnsafeBytes(of: &header) { control.replaceSubrange(0 ..< headerLength, with: $0) }
        withUnsafeBytes(of: &time) { raw in
            control.replaceSubrange(headerLength ..< headerLength + raw.count, with: raw)
        }

        XCTAssertEqual(NTPClient.receiveTimestamp(fromControl: control), 1_700_000_000.25)
        XCTAssertNil(NTPClient.receiveTimestamp(fromControl: []))
    }

    // MARK: - Helpers

    private func lastEstimate(pools: [String]) async -> NTPEstimate? {
        var estimate: NTPEstimate?
        for await update in NTPClient().query(pools: pools, numberOfSamples: 1, maximumServers: 1) {
            estimate = update.estimate
        }
        return estimate
    }

    private func peer(offset: TimeInterval, distance: TimeInterval, jitter: TimeInterval = 0,
                      stratum: Int = 2, leap: LeapIndicator = .noWarning) -> PeerEstimate
    {
        // With zero delays and dispersions, root distance is MINDISP / 2 + jitter + root dispersion.
        PeerEstimate(offset: offset, delay: 0, dispersion: 0, jitter: jitter, rootDelay: 0,
                            rootDispersion: distance - 0.0025 - jitter, stratum: stratum, leap: leap)
    }

    private func address(_ host: String) -> InternetAddress {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, host, &address.sin_addr)
        return .ipv4(address)
    }

    /// A server reply whose offset and delay come out as given, measured from a request sent at `now`.
    private func reply(now: TimeInterval, offset: TimeInterval, delay: TimeInterval) -> NTPPacket {
        let receive = now + delay / 2 + offset
        var bytes = [UInt8](repeating: 0, count: 48)
        bytes[0] = UInt8(4 << 3 | Mode.server.rawValue)
        bytes[1] = 2
        bytes[3] = UInt8(bitPattern: -20)
        for (index, time) in [now, receive, receive].enumerated() {
            let seconds = UInt64(time + 2208988800)
            let fraction = UInt64((time - floor(time)) * 4294967296.0)
            var timestamp = (seconds << 32 | fraction).bigEndian
            withUnsafeBytes(of: &timestamp) { raw in
                bytes.replaceSubrange(24 + index * 8 ..< 32 + index * 8, with: raw)
            }
        }
        // swiftlint:disable:next force_try
        return try! NTPPacket(data: Data(bytes), destinationTime: now + delay)
    }
}
