@testable import Kronos
import XCTest

final class ClockTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Clock.reset()
    }

    func testFirst() {
        let expectation = self.expectation(description: "Clock sync calls first closure")
        Clock.sync(first: { date, _ in
            XCTAssertNotNil(date)
            expectation.fulfill()
        })

        self.waitForExpectations(timeout: 2)
    }

    func testLast() {
        let expectation = self.expectation(description: "Clock sync calls last closure")
        Clock.sync(completion: { date, offset in
            XCTAssertNotNil(date)
            XCTAssertNotNil(offset)
            expectation.fulfill()
        })

        self.waitForExpectations(timeout: 20)
    }

    func testBoth() {
        let firstExpectation = self.expectation(description: "Clock sync calls first closure")
        let lastExpectation = self.expectation(description: "Clock sync calls last closure")
        Clock.sync(
            first: { _, _ in firstExpectation.fulfill() },
            completion: { _, _ in lastExpectation.fulfill() })

        self.waitForExpectations(timeout: 20)
    }

    func testFirstIsCalledOnMainThread() {
        let expectation = self.expectation(description: "Clock sync calls first closure on the main thread")
        Clock.sync(first: { _, _ in
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        })

        self.waitForExpectations(timeout: 2)
    }

    func testAsyncSync() async {
        let (date, offset) = await Clock.sync()
        XCTAssertNotNil(date)
        XCTAssertNotNil(offset)
        XCTAssertNotNil(Clock.now)
    }

    func testSyncingYieldsSamples() async {
        var samples: [SyncSample] = []
        for await sample in Clock.syncing() {
            samples.append(sample)
        }

        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(samples.map(\.completed), samples.map(\.completed).sorted())
        let measurements = samples.last?.measurements ?? []
        XCTAssertFalse(measurements.isEmpty)
        XCTAssertTrue(measurements.contains { $0.selected })
        XCTAssertTrue(measurements.allSatisfy { !$0.server.isEmpty && $0.stratum > 0 })
    }

    func testResetStopsSync() {
        let expectation = self.expectation(description: "Clock sync completes after reset")
        Clock.sync(completion: { date, _ in
            XCTAssertNil(date)
            expectation.fulfill()
        })
        Clock.reset()

        self.waitForExpectations(timeout: 20)
        XCTAssertNil(Clock.now)
    }
}
