@testable import Kronos
import XCTest

class TimeStoragePolicyTests: XCTestCase {
    func testInitWithStringGivesAppGroupType() {
        let group = TimeStoragePolicy(appGroupID: "com.test.something.mygreatapp")
        if case TimeStoragePolicy.appGroup(_) = group {
            XCTAssert(true)
        } else {
            XCTAssert(false)
        }
    }

    func testInitWithNIlGivesStandardType() {
        let group = TimeStoragePolicy(appGroupID: nil)
        if case TimeStoragePolicy.standard = group {
            XCTAssert(true)
        } else {
            XCTAssert(false)
        }
    }
}

class TimeStorageTests: XCTestCase {
    func testStoringAndRetrievingTimeFreeze() {
        var storage = TimeStorage(storagePolicy: .standard)
        let sampleFreeze = TimeFreeze(offset: 5000.32423)
        storage.stableTime = sampleFreeze

        let fromDefaults = storage.stableTime
        XCTAssertNotNil(fromDefaults)
        XCTAssertEqual(sampleFreeze.toDictionary(), fromDefaults!.toDictionary())
    }

    func testRetrievingTimeFreezeAfterReboot() {
        let sampleFreeze = TimeFreeze(offset: 5000.32423)
        var storedData = sampleFreeze.toDictionary()
        storedData["BootTime"] = storedData["BootTime"]! + 10

        let beforeRebootFreeze = TimeFreeze(from: sampleFreeze.toDictionary())
        let afterRebootFreeze = TimeFreeze(from: storedData)
        XCTAssertNil(afterRebootFreeze)
        XCTAssertNotNil(beforeRebootFreeze)
    }

    func testRejectsFreezeStoredWithoutBootTime() {
        var storedData = TimeFreeze(offset: 1).toDictionary()
        storedData["BootTime"] = nil
        XCTAssertNil(TimeFreeze(from: storedData))
    }
}

class TimeFreezeTests: XCTestCase {
    func testKeepsSubSecondOffset() {
        let freeze = TimeFreeze(offset: 0.25)
        XCTAssertEqual(freeze.adjustedTimestamp() - currentTime(), 0.25, accuracy: 0.01)
    }

    func testMeasuresFrequencyBetweenSynchronizations() {
        // A clock synchronized 2000 s ago, at 0 offset and 0 frequency, is now 0.02 s behind: 10 ppm fast.
        let now = currentTime()
        let uptime = TimeFreeze.systemUptime()
        let previous = TimeFreeze(from: [
            "Uptime": uptime - 2000, "Timestamp": now - 2000, "Offset": 0,
            "BootTime": TimeFreeze.bootTime(),
        ])!

        let freeze = TimeFreeze(offset: -0.02, previous: previous)
        let frequency = freeze.toDictionary()["Frequency"]!
        XCTAssertEqual(frequency, 0.25 * -10e-6, accuracy: 1e-7)
        XCTAssertEqual(freeze.toDictionary()["ReferenceUptime"]!, freeze.toDictionary()["Uptime"]!)
    }

    func testKeepsFrequencyForCloseSynchronizations() {
        let now = currentTime()
        let uptime = TimeFreeze.systemUptime()
        let previous = TimeFreeze(from: [
            "Uptime": uptime - 10, "Timestamp": now - 10, "Offset": 0, "BootTime": TimeFreeze.bootTime(),
            "Frequency": 3e-6, "ReferenceUptime": uptime - 10, "ReferenceTime": now - 10,
        ])!

        let freeze = TimeFreeze(offset: 0.5, previous: previous).toDictionary()
        XCTAssertEqual(freeze["Frequency"], 3e-6)
        XCTAssertEqual(freeze["ReferenceUptime"], uptime - 10)
    }

    func testIgnoresStepsWhenMeasuringFrequency() {
        let now = currentTime()
        let uptime = TimeFreeze.systemUptime()
        let previous = TimeFreeze(from: [
            "Uptime": uptime - 2000, "Timestamp": now - 2000, "Offset": 0, "BootTime": TimeFreeze.bootTime(),
        ])!

        // A two-second jump over 2000 s is 1000 ppm, a step rather than a rate.
        let freeze = TimeFreeze(offset: 2, previous: previous).toDictionary()
        XCTAssertEqual(freeze["Frequency"], 0)
    }

    func testStepsBackAfterInsertedLeapSecond() {
        let now = currentTime()
        let uptime = TimeFreeze.systemUptime()
        let pending = TimeFreeze(from: [
            "Uptime": uptime, "Timestamp": now, "Offset": 0, "BootTime": TimeFreeze.bootTime(),
            "LeapTime": now + 100, "LeapStep": -1,
        ])!
        let passed = TimeFreeze(from: [
            "Uptime": uptime, "Timestamp": now, "Offset": 0, "BootTime": TimeFreeze.bootTime(),
            "LeapTime": now - 100, "LeapStep": -1,
        ])!

        XCTAssertEqual(pending.adjustedTimestamp() - currentTime(), 0, accuracy: 0.01)
        XCTAssertEqual(passed.adjustedTimestamp() - currentTime(), -1, accuracy: 0.01)
    }

    func testAnnouncedLeapSecondIsAtEndOfMonth() {
        let freeze = TimeFreeze(offset: 0, leap: .fiftyNineSeconds).toDictionary()
        XCTAssertEqual(freeze["LeapStep"], 1)
        XCTAssertEqual(freeze["LeapTime"], TimeFreeze.startOfNextMonth(after: currentTime()))

        // 2016-12-31 12:00:00 UTC is followed by the leap second before 2017-01-01 00:00:00 UTC.
        XCTAssertEqual(TimeFreeze.startOfNextMonth(after: 1483185600), 1483228800)
    }

    func testUncertaintyGrowsAtFrequencyTolerance() {
        let now = currentTime()
        let uptime = TimeFreeze.systemUptime()
        let freeze = TimeFreeze(from: [
            "Uptime": uptime - 1000, "Timestamp": now - 1000, "Offset": 0,
            "BootTime": TimeFreeze.bootTime(), "RootDistance": 0.01,
        ])!

        XCTAssertEqual(freeze.uncertainty, 0.01 + 1000 * kFrequencyTolerance, accuracy: 1e-4)
        XCTAssertTrue(freeze.isSynchronized)
    }

    func testOldSynchronizationExceedsMaximumDistance() {
        let now = currentTime()
        let uptime = TimeFreeze.systemUptime()
        let freeze = TimeFreeze(from: [
            "Uptime": uptime - 200_000, "Timestamp": now - 200_000, "Offset": 0,
            "BootTime": TimeFreeze.bootTime(),
        ])!

        XCTAssertGreaterThan(freeze.uncertainty, kMaximumDistance)
        XCTAssertFalse(freeze.isSynchronized)
    }
}
