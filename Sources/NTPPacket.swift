import Foundation

/// Delta between system and NTP time
private let kEpochDelta = 2208988800.0

/// Width of one NTP era, in seconds. Timestamps are interpreted in the era closest to the current time.
private let kEraWidth = 4294967296.0

/// This is the maximum that we'll tolerate for the client's time vs self.delay
private let kMaximumDelayDifference = 0.1
private let kMaximumDispersion = 100.0

/// Frequency tolerance of the local clock, in seconds per second (RFC 5905 PHI).
let kFrequencyTolerance = 15e-6

/// A server or local clock whose root distance reaches this is not usable (ntpd `tos maxdist`).
let kMaximumDistance = 1.5

/// How often the clock is synchronized again, in seconds. Long enough that a new sample can measure
/// frequency, and short enough that the error bound stays inside `kMaximumDistance`.
let kPollInterval = 1024.0

/// Returns the current time in decimal EPOCH timestamp format.
///
/// - returns: The current time in EPOCH timestamp format.
func currentTime() -> TimeInterval {
    var current = timeval()
    let systemTimeError = gettimeofday(&current, nil) != 0
    assert(!systemTimeError, "system clock error: system time unavailable")

    return Double(current.tv_sec) + Double(current.tv_usec) / 1_000_000
}

/// Precision of `currentTime()` as a power of two in seconds, sent in the request's precision field.
///
/// RFC 5905 section 7.3 defines precision as the time to read the system clock, rounded to a power of two.
/// It is measured once as the smallest positive step between successive reads.
let kLocalPrecision: Int8 = {
    var tick = 1.0
    for _ in 0 ..< 32 {
        let start = currentTime()
        var next = start
        for _ in 0 ..< 100_000 where next == start {
            next = currentTime()
        }

        if next > start {
            tick = min(tick, next - start)
        }
    }

    return Int8(max(-32, min(0, Int(log2(tick).rounded(.down)))))
}()

struct NTPPacket {

    /// The leap indicator warning of an impending leap second to be inserted or deleted in the last
    /// minute of the current month.
    let leap: LeapIndicator

    /// Version Number (VN): 3-bit integer indicating the NTP version number. RFC 5905 defines this as 4.
    let version: Int8

    /// The current connection mode.
    let mode: Mode

    /// Mode representing the stratum level of the local clock.
    let stratum: Stratum

    /// Indicates the maximum interval between successive messages, in seconds to the nearest power of two.
    /// The values that normally appear in this field range from 6 to 10, inclusive.
    let poll: Int8

    /// The precision of the local clock, in seconds to the nearest power of two. The values that normally
    /// appear in this field range from -6 for mains-frequency clocks to -18 for microsecond clocks found
    /// in some workstations.
    let precision: Int8

    /// The total roundtrip delay to the primary reference source, in seconds with fraction point between
    /// bits 15 and 16. Note that this variable can take on both positive and negative values, depending on
    /// the relative time and frequency errors. The values that normally appear in this field range from
    /// negative values of a few milliseconds to positive values of several hundred milliseconds.
    let rootDelay: TimeInterval

    /// Total dispersion to the reference clock, in EPOCH.
    let rootDispersion: TimeInterval

    /// Server or reference clock. This value is generated based on a reference identifier maintained by IANA.
    let clockSource: ClockSource

    /// Time when the system clock was last set or corrected, in EPOCH timestamp format.
    let referenceTime: TimeInterval

    /// Time at the client when the request departed for the server, in EPOCH timestamp format.
    let originTime: TimeInterval

    /// Origin timestamp as the 64-bit NTP value from the packet, before conversion to seconds.
    let originTimestamp: UInt64

    /// Time at the server when the request arrived from the client, in EPOCH timestamp format.
    let receiveTime: TimeInterval

    /// Time at the server when the response left for the client, in EPOCH timestamp format.
    var transmitTime: TimeInterval = 0.0

    /// Transmit timestamp encoded for the wire. Set by ``prepareToSend(transmitTime:key:)``, or read from a
    /// received packet.
    private(set) var transmitTimestamp: UInt64 = 0

    /// Receive timestamp as the 64-bit NTP value from the packet.
    let receiveTimestamp: UInt64

    /// Stratum as the raw value from the packet (0 through 255).
    let stratumLevel: UInt8

    /// Time at the client when the response arrived, in EPOCH timestamp format.
    let destinationTime: TimeInterval

    /// NTP protocol package representation.
    ///
    /// - parameter transmitTime: Packet transmission timestamp.
    /// - parameter version:      NTP protocol version. RFC 5905 uses version 4.
    /// - parameter mode:         Packet mode (client, server).
    init(version: Int8 = 4, mode: Mode = .client) {
        self.version = version
        self.leap = .noWarning
        self.mode = mode
        self.stratum = .unspecified
        self.poll = 4
        self.precision = kLocalPrecision
        self.rootDelay = 1
        self.rootDispersion = 1
        self.clockSource = .referenceIdentifier(id: 0)
        self.referenceTime = -kEpochDelta
        self.originTime = -kEpochDelta
        self.originTimestamp = 0
        self.receiveTimestamp = 0
        self.stratumLevel = 0
        self.receiveTime = -kEpochDelta
        self.destinationTime = -1
    }

    /// Creates a NTP package based on a network PDU.
    ///
    /// - parameter data:            The PDU received from the NTP call.
    /// - parameter destinationTime: The time where the package arrived (client time) in EPOCH format.
    /// - throws:                    NTPParsingError in case of an invalid response.
    init(data: Data, destinationTime: TimeInterval) throws {
        if data.count < 48 {
            throw NTPParsingError.invalidNTPPDU("Invalid PDU length: \(data.count)")
        }

        let header = data.bigEndian(Int8.self, at: 0)
        let stratum = data.bigEndian(Int8.self, at: 1)
        self.leap = LeapIndicator(rawValue: (header >> 6) & 0b11) ?? .noWarning
        self.version = header >> 3 & 0b111
        self.mode = Mode(rawValue: header & 0b111) ?? .unknown
        self.stratum = Stratum(value: stratum)
        self.stratumLevel = UInt8(bitPattern: stratum)
        self.poll = data.bigEndian(Int8.self, at: 2)
        self.precision = data.bigEndian(Int8.self, at: 3)
        self.rootDelay = NTPPacket.signedIntervalFromNTPFormat(data.bigEndian(UInt32.self, at: 4))
        self.rootDispersion = NTPPacket.intervalFromNTPFormat(data.bigEndian(UInt32.self, at: 8))
        self.clockSource = ClockSource(stratum: self.stratum, sourceID: data.bigEndian(UInt32.self, at: 12))
        self.referenceTime = NTPPacket.dateFromNTPFormat(data.bigEndian(UInt64.self, at: 16))
        self.originTimestamp = data.bigEndian(UInt64.self, at: 24)
        self.originTime = NTPPacket.dateFromNTPFormat(self.originTimestamp)
        self.receiveTimestamp = data.bigEndian(UInt64.self, at: 32)
        self.receiveTime = NTPPacket.dateFromNTPFormat(self.receiveTimestamp)
        self.transmitTimestamp = data.bigEndian(UInt64.self, at: 40)
        self.transmitTime = NTPPacket.dateFromNTPFormat(self.transmitTimestamp)
        self.destinationTime = destinationTime
    }

    /// Convert this NTPPacket to a buffer that can be sent over a socket.
    ///
    /// - parameter transmitTime: Transmit time to write. Defaults to the current time.
    /// - parameter key:          Symmetric key. When set, the RFC 5905 MAC is appended after the header.
    /// - returns: A bytes buffer representing this packet.
    mutating func prepareToSend(transmitTime: TimeInterval? = nil, key: NTPKey? = nil) -> Data {
        var data = Data()
        data.reserveCapacity(48 + (key.map { 4 + $0.digestLength } ?? 0))
        data.appendBigEndian(self.leap.rawValue << 6 | self.version << 3 | self.mode.rawValue)
        data.appendBigEndian(self.stratum.rawValue)
        data.appendBigEndian(self.poll)
        data.appendBigEndian(self.precision)
        data.appendBigEndian(self.signedIntervalToNTPFormat(self.rootDelay))
        data.appendBigEndian(self.intervalToNTPFormat(self.rootDispersion))
        data.appendBigEndian(self.clockSource.ID)
        data.appendBigEndian(self.dateToNTPFormat(self.referenceTime))
        data.appendBigEndian(self.dateToNTPFormat(self.originTime))
        data.appendBigEndian(self.dateToNTPFormat(self.receiveTime))

        self.transmitTime = transmitTime ?? currentTime()
        self.transmitTimestamp = self.dateToNTPFormat(self.transmitTime)
        data.appendBigEndian(self.transmitTimestamp)
        if let key = key {
            data.append(key.messageAuthenticationCode(for: data))
        }
        return data
    }

    /// Checks the RFC 5905 MAC at the end of a received PDU.
    ///
    /// The MAC is the last 4 + digest bytes: the key ID, then the digest of the secret key concatenated with
    /// everything before it, including extension fields. A reply with a missing MAC, a different key ID or a
    /// crypto-NAK (key ID only) fails.
    ///
    /// - parameter data: The PDU received from the NTP call.
    /// - parameter key:  The key the request was sent with.
    /// - returns: `true` when the MAC matches.
    static func isAuthentic(_ data: Data, key: NTPKey) -> Bool {
        let macLength = 4 + key.digestLength
        guard data.count >= 48 + macLength else {
            return false
        }

        let data = Data(data)
        let message = data.prefix(data.count - macLength)
        let received = data.suffix(macLength)
        let expected = key.messageAuthenticationCode(for: message)

        // Compare every byte so the time taken does not depend on where the first mismatch is.
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(received, expected) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }

    /// Kiss code when this is a kiss-o'-death reply (a server reply with stratum 0), otherwise `nil`.
    var kissCode: KissCode? {
        guard (self.mode == .server || self.mode == .symmetricPassive) && self.stratum == .unspecified else {
            return nil
        }

        return KissCode(referenceID: self.clockSource.ID)
    }

    /// Checks properties to make sure that the received PDU is a valid response that we can use.
    ///
    /// RFC 5905 requires an acceptable version (1 through 4). When `transmitTimestamp` is present, the
    /// origin timestamp must echo that value; a mismatch means the packet is not the reply to this request.
    ///
    /// - parameter transmitTimestamp: 64-bit NTP transmit timestamp from the request, when known.
    /// - returns: A boolean indicating if the response is valid for the given version.
    func isValidResponse(matching transmitTimestamp: UInt64? = nil) -> Bool {
        let originMatches = transmitTimestamp == nil || self.originTimestamp == transmitTimestamp
        return originMatches
            && self.receiveTimestamp != 0 && self.transmitTimestamp != 0
            && (1 ... 4).contains(self.version)
            && (self.mode == .server || self.mode == .symmetricPassive) && self.leap != .alarm
            && self.stratum != .invalid && self.stratum != .unspecified
            && self.rootDispersion < kMaximumDispersion
            && abs(currentTime() - self.originTime - self.delay) < kMaximumDelayDifference
    }

    // MARK: - Private helpers

    private func dateToNTPFormat(_ time: TimeInterval) -> UInt64 {
        let integer = UInt64(time + kEpochDelta) & 0xffffffff
        let decimal = modf(time).1 * 4294967296.0 // 2 ^ 32
        return integer << 32 | UInt64(decimal)
    }

    private func intervalToNTPFormat(_ time: TimeInterval) -> UInt32 {
        let integer = UInt16(time)
        let decimal = modf(time).1 * 65536 // 2 ^ 16
        return UInt32(integer) << 16 | UInt32(decimal)
    }

    /// Root delay is a signed 16.16 NTP short. The seconds field can be negative.
    private func signedIntervalToNTPFormat(_ time: TimeInterval) -> UInt32 {
        let scaled = min(max(time * 65536.0, Double(Int32.min)), Double(Int32.max))
        return UInt32(bitPattern: Int32(scaled))
    }

    private static func signedIntervalFromNTPFormat(_ time: UInt32) -> TimeInterval {
        Double(Int32(bitPattern: time)) / 65536.0
    }

    /// Converts an NTP timestamp to seconds since 1970.
    ///
    /// The 32-bit seconds field repeats every era (136 years). RFC 5905 interprets it as the era within
    /// 2^31 seconds of the current clock, so a value just past the 2036 rollover stays on the near side
    /// of that boundary instead of being pinned to one era by its high bit.
    private static func dateFromNTPFormat(_ time: UInt64) -> TimeInterval {
        let seconds = UInt32(time >> 32)
        let fraction = Double(time & 0xffffffff) / kEraWidth
        let nowNTP = currentTime() + kEpochDelta
        let era = floor(nowNTP / kEraWidth)
        let lowSeconds = UInt32(nowNTP - era * kEraWidth)
        let delta = Int32(bitPattern: seconds &- lowSeconds)
        let ntpSeconds = era * kEraWidth + Double(lowSeconds) + Double(delta)
        return (ntpSeconds - kEpochDelta) + fraction
    }

    private static func intervalFromNTPFormat(_ time: UInt32) -> TimeInterval {
        let integer = Double(time >> 16)
        let decimal = Double(time & 0xffff) / 65536
        return integer + decimal
    }
}

/// From RFC 5905 section 8:
///
/// Timestamp Name          ID   When Generated
/// ------------------------------------------------------------
/// Originate Timestamp     T1   time request sent by client
/// Receive Timestamp       T2   time request received by server
/// Transmit Timestamp      T3   time reply sent by server
/// Destination Timestamp   T4   time reply received by client
///
/// The roundtrip delay d and local clock offset t are defined as
///
/// d = (T4 - T1) - (T3 - T2)     t = ((T2 - T1) + (T3 - T4)) / 2.
extension NTPPacket {

    /// Clocks offset in seconds.
    var offset: TimeInterval {
        ((self.receiveTime - self.originTime) + (self.transmitTime - self.destinationTime)) / 2.0
    }

    /// Round-trip delay in seconds
    var delay: TimeInterval {
        (self.destinationTime - self.originTime) - (self.transmitTime - self.receiveTime)
    }

    /// Dispersion of this sample in seconds (RFC 5905 section 8): the server and client precisions plus the
    /// frequency tolerance over the round trip.
    var dispersion: TimeInterval {
        pow(2.0, Double(self.precision)) + pow(2.0, Double(kLocalPrecision))
            + kFrequencyTolerance * (self.destinationTime - self.originTime)
    }
}
