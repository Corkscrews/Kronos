@testable import Kronos
import XCTest

final class DNSResolverTests: XCTestCase {

    func testComparesAddressesNumerically() {
        let lower = self.ipv4("10.0.0.2")
        let higher = self.ipv4("10.0.0.10")
        let sameHostOtherPort = self.ipv4("10.0.0.2", port: 123)

        XCTAssertLessThan(lower, higher)
        XCTAssertGreaterThan(higher, lower)
        XCTAssertEqual(lower, sameHostOtherPort)
        XCTAssertFalse(lower < sameHostOtherPort)
        XCTAssertLessThan(self.ipv4("255.255.255.255"), self.ipv6("::1"))
        XCTAssertLessThan(self.ipv6("::1"), self.ipv6("2001:db8::1"))
    }

    func testResolveOneIP() async {
        let addresses = await DNSResolver.resolve(host: "127.0.0.1")
        XCTAssertEqual(addresses.map(\.host), ["127.0.0.1"])
    }

    func testResolveMultipleIP() async {
        let addresses = await DNSResolver.resolve(host: "pool.ntp.org")
        XCTAssertGreaterThan(addresses.count, 1)
    }

    func testResolveIPv6() async {
        let addresses = await DNSResolver.resolve(host: "ipv6friday.org")
        XCTAssertGreaterThan(addresses.count, 0)
    }

    func testInvalidIP() async {
        let addresses = await DNSResolver.resolve(host: "l33t.h4x")
        XCTAssertEqual(addresses.count, 0)
    }

    func testTimeout() async {
        let start = Date()
        let addresses = await DNSResolver.resolve(host: "ip6.nl", timeout: 0)
        XCTAssertEqual(addresses.count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testCancellation() async {
        let lookup = Task { await DNSResolver.resolve(host: "ip6.nl", timeout: 60) }
        lookup.cancel()

        let addresses = await lookup.value
        XCTAssertEqual(addresses.count, 0)
    }

    func testTemporaryRunloopHandling() {
        let expectation = self.expectation(description: "Query works from async GCD queues")
        DispatchQueue(label: "Ephemeral DNS test queue").async {
            Task {
                _ = await DNSResolver.resolve(host: "lyft.com")
                expectation.fulfill()
            }
        }

        self.waitForExpectations(timeout: 5)
    }

    private func ipv4(_ host: String, port: Int = 0) -> InternetAddress {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        return .ipv4(address)
    }

    private func ipv6(_ host: String) -> InternetAddress {
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        inet_pton(AF_INET6, host, &address.sin6_addr)
        return .ipv6(address)
    }
}
