import Foundation

private let kUptimeKey = "Uptime"
private let kTimestampKey = "Timestamp"
private let kOffsetKey = "Offset"
private let kBootTimeKey = "BootTime"
private let kFrequencyKey = "Frequency"
private let kReferenceUptimeKey = "ReferenceUptime"
private let kReferenceTimeKey = "ReferenceTime"
private let kLeapTimeKey = "LeapTime"
private let kLeapStepKey = "LeapStep"
private let kRootDistanceKey = "RootDistance"

/// Shortest interval between two synchronizations used to measure frequency. Shorter intervals are
/// dominated by network jitter (RFC 5905 uses the FLL only above its 2048 second Allan intercept).
private let kMinimumFrequencyInterval = 1024.0

/// Largest frequency correction applied, in seconds per second (RFC 5905 MAXFREQ).
private let kMaximumFrequency = 500e-6

/// Weight of each new frequency measurement against the running estimate (RFC 5905 FLL AVG of 4).
private let kFrequencyGain = 0.25

struct TimeFreeze {
    private let uptime: TimeInterval
    private let timestamp: TimeInterval
    private let offset: TimeInterval
    private let bootTime: TimeInterval

    /// Rate error of the monotonic clock, in seconds per second. Added to every elapsed second.
    private let frequency: TimeInterval

    /// Monotonic time and NTP time of the synchronization that frequency is next measured from.
    private let referenceUptime: TimeInterval
    private let referenceTime: TimeInterval

    /// Start of the month after the synchronization when a leap second was announced, otherwise 0.
    private let leapTime: TimeInterval

    /// -1 when a second is inserted, +1 when one is deleted, otherwise 0.
    private let leapStep: TimeInterval

    /// Root distance at synchronization, in seconds.
    private let rootDistance: TimeInterval

    /// The stable timestamp adjusted by the most accurate offset known so far, corrected for frequency and
    /// stepped once an announced leap second has passed.
    func adjustedTimestamp(atUptime uptime: TimeInterval = TimeFreeze.systemUptime()) -> TimeInterval {
        let time = self.extrapolatedTime(atUptime: uptime)
        if self.leapStep < 0 && time >= self.leapTime {
            // The inserted second repeats 23:59:59, then the clock is one second behind the extrapolation.
            return time + self.leapStep
        }
        if self.leapStep > 0 && time >= self.leapTime - 1 {
            // 23:59:59 does not exist, so the clock is one second ahead of the extrapolation.
            return time + self.leapStep
        }
        return time
    }

    /// Date, age, and error bound at one monotonic instant. `nil` once that bound passes the distance at
    /// which a server would be rejected.
    func annotated(atUptime uptime: TimeInterval = TimeFreeze.systemUptime()) -> AnnotatedTime? {
        let age = uptime - self.uptime
        let uncertainty = self.rootDistance + kFrequencyTolerance * max(0, age)
        guard uncertainty <= kMaximumDistance else { return nil }
        return AnnotatedTime(date: Date(timeIntervalSince1970: self.adjustedTimestamp(atUptime: uptime)),
                             timeSinceLastNtpSync: age, uncertainty: uncertainty)
    }

    /// The stable timestamp: the system time of the synchronization plus the monotonic time since.
    var stableTimestamp: TimeInterval {
        (TimeFreeze.systemUptime() - self.uptime) + self.timestamp
    }

    /// Time interval between now and the time the NTP response represented by this TimeFreeze was received.
    var timeSinceLastNtpSync: TimeInterval {
        TimeFreeze.systemUptime() - uptime
    }

    /// Bound on the clock error, in seconds. Starts at the system peer's root distance and grows at the
    /// frequency tolerance until the next synchronization.
    var uncertainty: TimeInterval {
        self.rootDistance + kFrequencyTolerance * max(0, self.timeSinceLastNtpSync)
    }

    /// `false` once `uncertainty` passes the distance at which a server would be rejected.
    var isSynchronized: Bool {
        self.uncertainty <= kMaximumDistance
    }

    /// - parameter offset:       Offset between NTP time and the system clock, in seconds.
    /// - parameter leap:         Leap indicator the servers announced.
    /// - parameter rootDistance: Root distance of the synchronization, in seconds.
    /// - parameter previous:     The clock before this synchronization pass. When it is from at least 1024
    ///                           seconds earlier, the difference between its prediction and `offset` updates
    ///                           the frequency estimate; otherwise its frequency is kept.
    init(offset: TimeInterval, leap: LeapIndicator = .noWarning, rootDistance: TimeInterval = 0,
         previous: TimeFreeze? = nil)
    {
        let uptime = TimeFreeze.systemUptime()
        let timestamp = currentTime()
        let time = offset + timestamp

        self.offset = offset
        self.timestamp = timestamp
        self.uptime = uptime
        self.bootTime = TimeFreeze.bootTime()

        var frequency = previous?.frequency ?? 0
        var referenceUptime = previous?.referenceUptime ?? uptime
        var referenceTime = previous?.referenceTime ?? time
        if let previous = previous {
            let elapsed = uptime - previous.referenceUptime
            if elapsed >= kMinimumFrequencyInterval {
                let predicted = previous.referenceTime + elapsed * (1 + previous.frequency)
                let error = (time - predicted) / elapsed
                // A larger error is a step, such as a leap second, not a rate. Start measuring again.
                if abs(error) < kMaximumFrequency {
                    frequency = min(max(frequency + kFrequencyGain * error, -kMaximumFrequency), kMaximumFrequency)
                }
                referenceUptime = uptime
                referenceTime = time
            }
        }
        self.frequency = frequency
        self.referenceUptime = referenceUptime
        self.referenceTime = referenceTime

        switch leap {
        case .sixtyOneSeconds:
            self.leapTime = TimeFreeze.startOfNextMonth(after: time)
            self.leapStep = -1

        case .fiftyNineSeconds:
            self.leapTime = TimeFreeze.startOfNextMonth(after: time)
            self.leapStep = 1

        case .noWarning, .alarm:
            self.leapTime = 0
            self.leapStep = 0
        }
        self.rootDistance = rootDistance
    }

    init?(from dictionary: [String: TimeInterval]) {
        guard let uptime = dictionary[kUptimeKey], let timestamp = dictionary[kTimestampKey],
            let offset = dictionary[kOffsetKey], let bootTime = dictionary[kBootTimeKey] else
        {
            return nil
        }

        // Monotonic time restarts at boot, so a stored value from another boot cannot be extrapolated.
        if rint(bootTime) != rint(TimeFreeze.bootTime()) || uptime > TimeFreeze.systemUptime() {
            return nil
        }

        self.uptime = uptime
        self.timestamp = timestamp
        self.offset = offset
        self.bootTime = bootTime
        self.frequency = dictionary[kFrequencyKey] ?? 0
        self.referenceUptime = dictionary[kReferenceUptimeKey] ?? uptime
        self.referenceTime = dictionary[kReferenceTimeKey] ?? offset + timestamp
        self.leapTime = dictionary[kLeapTimeKey] ?? 0
        self.leapStep = dictionary[kLeapStepKey] ?? 0
        self.rootDistance = dictionary[kRootDistanceKey] ?? 0
    }

    /// Convert this TimeFreeze to a dictionary representation.
    ///
    /// - returns: A dictionary representation.
    func toDictionary() -> [String: TimeInterval] {
        [
            kUptimeKey: self.uptime,
            kTimestampKey: self.timestamp,
            kOffsetKey: self.offset,
            kBootTimeKey: self.bootTime,
            kFrequencyKey: self.frequency,
            kReferenceUptimeKey: self.referenceUptime,
            kReferenceTimeKey: self.referenceTime,
            kLeapTimeKey: self.leapTime,
            kLeapStepKey: self.leapStep,
            kRootDistanceKey: self.rootDistance,
        ]
    }

    /// NTP time at the given monotonic time, before any leap second step.
    private func extrapolatedTime(atUptime uptime: TimeInterval) -> TimeInterval {
        let elapsed = uptime - self.uptime
        return self.offset + self.timestamp + elapsed * (1 + self.frequency)
    }

    /// Returns a high-resolution measurement of system uptime, that continues ticking through device sleep
    /// *and* user- or system-generated clock adjustments. This allows for stable differences to be calculated
    /// between timestamps.
    ///
    /// Darwin's `CLOCK_MONOTONIC` counts nanoseconds since boot, including time asleep, and is not stepped
    /// when the wall clock changes.
    ///
    /// - returns: Seconds since boot.
    static func systemUptime() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// Kernel boot time in EPOCH format. Identifies the boot that monotonic times belong to.
    static func bootTime() -> TimeInterval {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var size = MemoryLayout<timeval>.stride
        var bootTime = timeval()

        let bootTimeError = sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0) != 0
        assert(!bootTimeError, "system clock error: kernel boot time unavailable")

        return Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000
    }

    /// First second of the UTC month after `time`, in EPOCH format. Leap seconds happen at the end of a month.
    static func startOfNextMonth(after time: TimeInterval) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: time)
        let month = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: month)!
        return calendar.date(byAdding: .month, value: 1, to: start)!.timeIntervalSince1970
    }
}
