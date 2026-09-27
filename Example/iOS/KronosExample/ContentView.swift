import Kronos
import SwiftUI

struct ContentView: View {
    @StateObject private var model = ExampleModel()

    var body: some View {
        ExampleScreen(model: self.model)
            .preferredColorScheme(.dark)
    }
}

private struct ExampleScreen: View {
    @ObservedObject var model: ExampleModel

    var body: some View {
        ZStack {
            Phosphor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    self.header
                    LiveTimeSection(
                        isSyncing: self.model.isSyncing,
                        offset: self.model.offset,
                        completed: self.model.completed,
                        total: self.model.total,
                        bestRoundTrip: self.bestRoundTrip
                    )
                    if !self.model.measurements.isEmpty {
                        MeasurementList(measurements: self.model.measurements)
                    }
                    self.controls
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Kronos")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Phosphor.bright)
            Text("Monotonic NTP clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.poolPicker
            HStack(spacing: 12) {
                self.syncButton
                self.resetButton
            }
            Text(
                "S syncs with \(self.model.pool.hostname). Choosing another pool syncs again. "
                    + "NTP time keeps counting if the device clock changes."
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if self.model.didFail {
                Text("No response from \(self.model.pool.hostname). Check the simulator network, then sync again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var poolPicker: some View {
        HStack(spacing: 12) {
            Text("Pool")
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Picker("Pool", selection: self.poolSelection) {
                ForEach(NTPPool.allCases) { pool in
                    Text(pool.hostname).tag(pool)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Phosphor.bright)
            .accessibilityIdentifier("pool")
        }
        .font(.subheadline)
        .padding(.horizontal, 4)
    }

    /// Smallest round trip among the replies the clock filter kept.
    private var bestRoundTrip: TimeInterval? {
        self.model.measurements.filter(\.selected).map(\.roundTripDelay).min()
    }

    private var poolSelection: Binding<NTPPool> {
        Binding(
            get: { self.model.pool },
            set: { self.model.select($0) }
        )
    }

    private var syncButton: some View {
        Button(action: self.model.sync) {
            HStack(spacing: 8) {
                if self.model.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black)
                }
                Text(self.model.isSyncing ? "Syncing" : "Sync")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(FilledClockButtonStyle())
        .allowsHitTesting(!self.model.isSyncing)
        .keyboardShortcut("s", modifiers: [])
        .accessibilityIdentifier("sync")
    }

    private var resetButton: some View {
        Button("Reset", action: self.model.reset)
            .buttonStyle(OutlineClockButtonStyle())
            .keyboardShortcut("r", modifiers: [])
            .accessibilityIdentifier("reset")
    }
}

/// Owns the only continuously updating part of the screen. Keeping the timeline here prevents
/// controls such as the pool menu from being rebuilt every time the clock advances.
private struct LiveTimeSection: View {
    let isSyncing: Bool
    let offset: TimeInterval?
    let completed: Int
    let total: Int
    let bestRoundTrip: TimeInterval?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let ntpTime = Clock.annotatedNow

            VStack(alignment: .leading, spacing: 20) {
                self.clocks(deviceDate: timeline.date, ntpDate: ntpTime?.date)
                self.metrics(ntpTime: ntpTime)
            }
        }
    }

    private func clocks(deviceDate: Date, ntpDate: Date?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                self.ntpPanel(date: ntpDate)
                ClockPanel(title: "Clock date", date: deviceDate, lit: true)
            }
            VStack(spacing: 16) {
                self.ntpPanel(date: ntpDate)
                ClockPanel(title: "Clock date", date: deviceDate, lit: true)
            }
        }
    }

    private func ntpPanel(date: Date?) -> some View {
        ClockPanel(title: self.ntpTitle(hasDate: date != nil), date: date, lit: date != nil)
    }

    private func metrics(ntpTime: AnnotatedTime?) -> some View {
        VStack(spacing: 8) {
            MetricRow(label: "Offset", value: self.offsetText(hasDate: ntpTime != nil))
            MetricRow(label: "Uncertainty", value: self.milliseconds(ntpTime?.uncertainty))
            MetricRow(label: "Best RTT", value: self.milliseconds(self.bestRoundTrip))
            MetricRow(label: "Since sync", value: self.seconds(ntpTime?.timeSinceLastNtpSync))
            if let progressText = self.progressText {
                MetricRow(label: "Attempts", value: progressText)
            }
        }
        .padding(.horizontal, 4)
    }

    private func ntpTitle(hasDate: Bool) -> String {
        if hasDate {
            return "NTP date"
        }
        return self.isSyncing ? "Syncing" : "Not sync'ed"
    }

    private func offsetText(hasDate: Bool) -> String {
        guard let offset = self.offset, hasDate else {
            return "—"
        }
        return String(format: "%+.1f ms", offset * 1_000)
    }

    private var progressText: String? {
        guard self.total > 0 else {
            return nil
        }
        return "\(self.completed) / \(self.total)"
    }

    private func milliseconds(_ value: TimeInterval?) -> String {
        guard let value else {
            return "—"
        }
        return String(format: "%.1f ms", value * 1_000)
    }

    private func seconds(_ value: TimeInterval?) -> String {
        guard let value else {
            return "—"
        }
        return String(format: "%.1f s", value)
    }
}

private struct MeasurementList: View {
    let measurements: [NTPMeasurement]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: self.toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Measurements")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Phosphor.bright.opacity(0.9))
                    Spacer(minLength: 8)
                    Text("\(self.measurements.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Phosphor.bright)
                        .rotationEffect(.degrees(self.expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Measurements")
            .accessibilityValue("\(self.measurements.count) replies, \(self.expanded ? "expanded" : "collapsed")")
            .accessibilityHint(self.expanded ? "Hides each reply" : "Shows each reply")

            if self.expanded {
                Text("Each row is one reply. Kronos keeps the lowest round trip from each server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(self.measurements.enumerated()), id: \.offset) { _, measurement in
                    MeasurementRow(measurement: measurement, queued: self.queued(measurement))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Phosphor.bright.opacity(0.28), lineWidth: 1)
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) {
            self.expanded.toggle()
        }
    }

    /// A reply this far above its server's kept round trip has usually been queued.
    private func queued(_ measurement: NTPMeasurement) -> Bool {
        guard !measurement.selected,
            let kept = self.measurements.first(where: { $0.server == measurement.server && $0.selected }) else
        {
            return false
        }
        return measurement.roundTripDelay > kept.roundTripDelay + 0.05
    }
}

private struct MeasurementRow: View {
    let measurement: NTPMeasurement
    let queued: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.measurement.server)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Phosphor.bright)
                Text("stratum \(self.measurement.stratum)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if self.measurement.selected {
                    Text("lowest RTT")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Phosphor.bright)
                }
            }
            HStack(spacing: 12) {
                Text(self.milliseconds(self.measurement.offset, signed: true))
                Text("\(self.milliseconds(self.measurement.roundTripDelay)) RTT")
                Text(self.dispersion)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(self.valueColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.measurement.server)
        .accessibilityValue(self.accessibilityValue)
    }

    private var dispersion: String {
        String(format: "%.3f ms dispersion", self.measurement.dispersion * 1_000)
    }

    private var valueColor: Color {
        if self.queued {
            return .orange
        }
        return Phosphor.bright.opacity(self.measurement.selected ? 1 : 0.55)
    }

    private var accessibilityValue: String {
        let kept = self.measurement.selected ? "lowest round trip" : (self.queued ? "queued" : "reply")
        return "\(kept), stratum \(self.measurement.stratum), "
            + "\(self.milliseconds(self.measurement.offset, signed: true)), "
            + "\(self.milliseconds(self.measurement.roundTripDelay)) round trip"
    }

    private func milliseconds(_ value: TimeInterval, signed: Bool = false) -> String {
        String(format: signed ? "%+.1f ms" : "%.1f ms", value * 1_000)
    }
}

private struct ClockPanel: View {
    let title: String
    let date: Date?
    let lit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Phosphor.bright.opacity(0.9))
            LEDClock(date: self.date, lit: self.lit)
            Text(self.stamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Phosphor.bright.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.title)
        .accessibilityValue(self.stamp)
    }

    private var stamp: String {
        guard let date = self.date else {
            return "—"
        }
        return ClockStamp.string(from: date)
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(self.label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(self.value)
                .monospacedDigit()
                .foregroundStyle(Phosphor.bright)
        }
        .font(.subheadline)
    }
}

private struct FilledClockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Phosphor.bright.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

private struct OutlineClockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Phosphor.bright)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .overlay {
                Capsule().stroke(Phosphor.bright.opacity(configuration.isPressed ? 0.45 : 0.9), lineWidth: 1)
            }
    }
}

private enum ClockStamp {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd  HH:mm:ss zzz"
        return formatter
    }()

    static func string(from date: Date) -> String {
        let text = self.formatter.string(from: date)
        let milliseconds = String(format: "%03d", ClockDigits.milliseconds(from: date))
        guard let space = text.lastIndex(of: " ") else {
            return "\(text).\(milliseconds)"
        }
        return "\(text[..<space]).\(milliseconds)\(text[space...])"
    }
}

#Preview {
    ContentView()
}
