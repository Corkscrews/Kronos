@testable import Kronos
import XCTest

final class NTPPacketTests: XCTestCase {
    func testToData() {
        var packet = NTPPacket()
        var data = packet.prepareToSend(transmitTime: 1463303662.776552)
        XCTAssertEqual(data.bigEndian(Int8.self, at: 3), kLocalPrecision)

        data[3] = 0xfa
        XCTAssertEqual(data, Data(hex: "230004fa0001000000010000000000000000000000000000" +
                                       "00000000000000000000000000000000dae2bc6ec6cc1c00")!)
    }

    func testMeasuredPrecisionIsFinerThanMilliseconds() {
        // gettimeofday ticks in microseconds, so precision is about 2^-20 rather than the old 2^-6.
        XCTAssertLessThan(kLocalPrecision, -10)
        XCTAssertGreaterThanOrEqual(kLocalPrecision, -32)
    }

    func testAuthenticatedRequestRoundTrips() {
        for algorithm in [NTPKey.Algorithm.md5, .sha1] {
            let key = NTPKey(id: 7, secret: Data("secret".utf8), algorithm: algorithm)
            var packet = NTPPacket()
            let data = packet.prepareToSend(key: key)

            XCTAssertEqual(data.count, 48 + 4 + key.digestLength)
            XCTAssertEqual(data.bigEndian(UInt32.self, at: 48), 7)
            XCTAssertTrue(NTPPacket.isAuthentic(data, key: key))

            var tampered = data
            tampered[40] ^= 1
            XCTAssertFalse(NTPPacket.isAuthentic(tampered, key: key))
            XCTAssertFalse(NTPPacket.isAuthentic(data, key: NTPKey(id: 7, secret: Data("other".utf8),
                                                                   algorithm: algorithm)))
            XCTAssertFalse(NTPPacket.isAuthentic(data.prefix(48), key: key))
        }
    }

    func testMD5MACMatchesRFC5905Construction() {
        // MD5("key" + 48 zero bytes), computed with Python hashlib.
        let key = NTPKey(id: 1, secret: Data("key".utf8), algorithm: .md5)
        let mac = key.messageAuthenticationCode(for: Data(count: 48))
        XCTAssertEqual(mac, Data(hex: "00000001" + "e20e96ab3803fa6f124d92eaf78a5d45")!)
    }

    func testParsesKissOfDeath() {
        var bytes = [UInt8](repeating: 0, count: 48)
        bytes[0] = UInt8(4 << 3 | Mode.server.rawValue)
        bytes.replaceSubrange(12 ..< 16, with: Array("RATE".utf8))
        // swiftlint:disable:next force_try
        let PDU = try! NTPPacket(data: Data(bytes), destinationTime: 0)

        XCTAssertEqual(PDU.kissCode, .rateExceeded)
        XCTAssertFalse(PDU.isValidResponse())
        XCTAssertEqual(KissCode(referenceID: 0x44454e59), .deny)
        XCTAssertEqual(KissCode(referenceID: 0x52535452), .restricted)
        XCTAssertNil(serverReply(originTimestamp: 1, version: 4).kissCode)
    }

    func testParseInvalidData() {
        let network = Data(hex: "0badface")!
        let PDU = try? NTPPacket(data: network, destinationTime: 0)
        XCTAssertNil(PDU)
    }

    func testParseData() {
        let network = Data(hex: "1c0203e90000065700000a68ada2c09cdae2d084a5a76d5fdae2d3354a529000dae2d32b" +
                                "b38bab46dae2d32bb38d9e00")!
        let PDU = try? NTPPacket(data: network, destinationTime: 0)
        XCTAssertEqual(PDU?.version, 3)
        XCTAssertEqual(PDU?.leap, LeapIndicator.noWarning)
        XCTAssertEqual(PDU?.mode, Mode.server)
        XCTAssertEqual(PDU?.stratum, Stratum.secondary)
        XCTAssertEqual(PDU?.poll, 3)
        XCTAssertEqual(PDU?.precision, -23)
    }

    func testParseDataFromSlice() {
        // Offsets count from the first byte of the slice, not from the start of the underlying buffer.
        let buffer = Data(hex: "ffffffff1c0203e90000065700000a68ada2c09cdae2d084a5a76d5fdae2d3354a529000" +
                               "dae2d32bb38bab46dae2d32bb38d9e00")!
        let network = buffer.suffix(from: 4)
        XCTAssertEqual(network.startIndex, 4)

        let PDU = try? NTPPacket(data: network, destinationTime: 0)
        XCTAssertEqual(PDU?.version, 3)
        XCTAssertEqual(PDU?.mode, Mode.server)
        XCTAssertEqual(PDU?.precision, -23)
        XCTAssertEqual(PDU?.clockSource.ID, 2913124508)
        XCTAssertEqual(PDU?.receiveTime, 1463309483.7013499737)
    }

    func testHexRejectsNonHexDigits() {
        XCTAssertEqual(Data(hex: "00ffAb"), Data([0x00, 0xff, 0xab]))
        XCTAssertNil(Data(hex: "+f"))
        XCTAssertNil(Data(hex: "-0"))
        XCTAssertNil(Data(hex: "0g"))
        XCTAssertNil(Data(hex: "abc"))
    }

    func testParseTimeData() {
        let network = Data(hex: "1c0203e90000065700000a68ada2c09cdae2d084a5a76d5fdae2d3354a529000dae2d32b" +
                                "b38bab46dae2d32bb38d9e00")!
        let PDU = try? NTPPacket(data: network, destinationTime: 0)
        XCTAssertEqual(PDU?.rootDelay, 0.0247650146484375)
        XCTAssertEqual(PDU?.rootDispersion, 0.0406494140625)
        XCTAssertEqual(PDU?.clockSource.ID, 2913124508)
        XCTAssertEqual(PDU?.referenceTime, 1463308804.6470859051)
        XCTAssertEqual(PDU?.originTime, 1463309493.2903223038)
        XCTAssertEqual(PDU?.receiveTime, 1463309483.7013499737)
    }

    func testParseYear2036() {
        let formatter = DateFormatter()
        let hexWithRollover = "1b0004fa000100000001000000000000000000000000000000000000000000000000000" +
                              "0000000000000000000000000"
        formatter.dateFormat = "YYYY-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        let networkData = Data(hex: hexWithRollover)!
        var PDU = try? NTPPacket(data: networkData, destinationTime: 0)
        let referenceTime = PDU.map { Date(timeIntervalSince1970: $0.referenceTime) }
        XCTAssertEqual(formatter.string(for: referenceTime), "2036-02-07 06:28:16")

        // The rollover happens at 2^32 - epoch_delta = 2,085,978,496
        XCTAssertEqual(PDU?.prepareToSend(transmitTime: 2085978496), networkData)
    }

    func testStratumRangeMatchesRFC5905() {
        XCTAssertEqual(Stratum(value: 0), .unspecified)
        XCTAssertEqual(Stratum(value: 1), .primary)
        XCTAssertEqual(Stratum(value: 15), .secondary)
        XCTAssertEqual(Stratum(value: 16), .invalid)
    }

    func testParsesNegativeRootDelay() {
        let network = Data(hex: "1c0203e9ffff800000000a68ada2c09cdae2d084a5a76d5fdae2d3354a529000dae2d32b" +
                                "b38bab46dae2d32bb38d9e00")!
        let PDU = try? NTPPacket(data: network, destinationTime: 0)
        XCTAssertEqual(PDU?.rootDelay, -0.5)
    }

    func testRejectsReplyThatDoesNotEchoTheRequest() {
        var request = NTPPacket(version: 4)
        _ = request.prepareToSend(transmitTime: currentTime())
        let sent = request.transmitTimestamp
        let reply = serverReply(originTimestamp: sent, version: 4)
        XCTAssertTrue(reply.isValidResponse(matching: sent))

        let other = serverReply(originTimestamp: sent &+ 1, version: 4)
        XCTAssertFalse(other.isValidResponse(matching: sent))
        XCTAssertFalse(serverReply(originTimestamp: sent, version: 5).isValidResponse(matching: sent))
    }

    private func serverReply(originTimestamp: UInt64, version: Int8) -> NTPPacket {
        var bytes = [UInt8](repeating: 0, count: 48)
        let mode = Int8(Mode.server.rawValue)
        bytes[0] = UInt8(bitPattern: version << 3 | mode)
        bytes[1] = 1
        bytes[2] = 4
        bytes[3] = UInt8(bitPattern: -6)
        var timestamp = originTimestamp.bigEndian
        withUnsafeBytes(of: &timestamp) { raw in
            for offset in 0 ..< 8 {
                bytes[24 + offset] = raw[offset]
                bytes[32 + offset] = raw[offset]
                bytes[40 + offset] = raw[offset]
            }
        }
        // swiftlint:disable:next force_try
        return try! NTPPacket(data: Data(bytes), destinationTime: currentTime())
    }
}
