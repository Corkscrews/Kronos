import SwiftUI

enum Phosphor {
    static let bright = Color(red: 0.47, green: 1, blue: 0.56)
    static let dim = Color(red: 0.16, green: 0.32, blue: 0.18)
    static let off = Color(red: 0.05, green: 0.08, blue: 0.06)
    static let background = Color(red: 0.012, green: 0.02, blue: 0.014)
}

struct LEDClock: View {
    let date: Date?
    var lit = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LEDFace(date: self.date, lit: self.lit,
                    digitSize: CGSize(width: 30, height: 52),
                    millisecondSize: CGSize(width: 16, height: 28))
            LEDFace(date: self.date, lit: self.lit,
                    digitSize: CGSize(width: 22, height: 38),
                    millisecondSize: CGSize(width: 12, height: 22))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LEDFace: View {
    let date: Date?
    let lit: Bool
    let digitSize: CGSize
    let millisecondSize: CGSize

    var body: some View {
        let digits = ClockDigits(date: self.date)
        HStack(alignment: .bottom, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                self.digits(digits.hour, size: self.digitSize)
                self.colon
                self.digits(digits.minute, size: self.digitSize)
                self.colon
                self.digits(digits.second, size: self.digitSize)
            }
            HStack(alignment: .center, spacing: 3) {
                self.decimal
                self.milliseconds(digits.millisecond)
            }
            .padding(.bottom, self.digitSize.height * 0.04)
        }
        .shadow(color: Phosphor.bright.opacity(self.lit ? 0.55 : 0), radius: 10)
        .accessibilityHidden(true)
    }

    private var colon: some View {
        LEDColon(lit: self.colonLit, on: self.segmentOn, off: Phosphor.off, height: self.digitSize.height)
    }

    private var decimal: some View {
        Circle()
            .fill(self.segmentOn)
            .frame(width: self.dotSize, height: self.dotSize)
    }

    private var colonLit: Bool {
        guard let date = self.date, self.lit else {
            return false
        }
        let second = Int(date.timeIntervalSinceReferenceDate.rounded(.down))
        return second.isMultiple(of: 2)
    }

    private var segmentOn: Color {
        self.lit ? Phosphor.bright : Phosphor.dim
    }

    private var dotSize: CGFloat {
        max(4, self.digitSize.height * 0.11)
    }

    private func digits(_ value: Int, size: CGSize) -> some View {
        HStack(spacing: 2) {
            self.digit(value / 10, size: size)
            self.digit(value % 10, size: size)
        }
    }

    private func milliseconds(_ value: Int) -> some View {
        let value = min(max(value, 0), 999)
        return HStack(spacing: 2) {
            self.digit(value / 100, size: self.millisecondSize)
            self.digit((value / 10) % 10, size: self.millisecondSize)
            self.digit(value % 10, size: self.millisecondSize)
        }
    }

    private func digit(_ value: Int, size: CGSize) -> some View {
        SevenSegmentDigit(value: value, on: self.segmentOn, off: Phosphor.off, size: size)
    }
}

struct ClockDigits {
    var hour = 0
    var minute = 0
    var second = 0
    var millisecond = 0

    init(date: Date?) {
        guard let date else {
            return
        }

        let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        self.hour = parts.hour ?? 0
        self.minute = parts.minute ?? 0
        self.second = parts.second ?? 0
        self.millisecond = (parts.nanosecond ?? 0) / 1_000_000
    }

    /// Milliseconds shown beside the seconds, truncated the same way as the digits.
    static func milliseconds(from date: Date) -> Int {
        ClockDigits(date: date).millisecond
    }
}

private struct LEDColon: View {
    let lit: Bool
    let on: Color
    let off: Color
    let height: CGFloat

    var body: some View {
        VStack(spacing: self.height * 0.22) {
            self.dot
            self.dot
        }
        .frame(height: self.height)
    }

    private var dot: some View {
        let side = max(4, self.height * 0.11)
        return Circle()
            .fill(self.lit ? self.on : self.off)
            .frame(width: side, height: side)
    }
}

private struct SevenSegmentDigit: View {
    let value: Int
    let on: Color
    let off: Color
    let size: CGSize

    var body: some View {
        Canvas { context, size in
            self.draw(context: context, size: size)
        }
        .frame(width: self.size.width, height: self.size.height)
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let mask = Self.masks[min(max(self.value, 0), 9)]
        for (index, rect) in Self.segments(in: size).enumerated() {
            let active = (mask & (1 << index)) != 0
            let corner = min(rect.width, rect.height) / 2
            let path = Path(roundedRect: rect, cornerRadius: corner)
            context.fill(path, with: .color(active ? self.on : self.off))
        }
    }

    /// Bits, low to high: top, upper right, lower right, bottom, lower left, upper left, middle.
    private static let masks = [
        0b0111111,
        0b0000110,
        0b1011011,
        0b1001111,
        0b1100110,
        0b1101101,
        0b1111101,
        0b0000111,
        0b1111111,
        0b1101111,
    ]

    private static func segments(in size: CGSize) -> [CGRect] {
        let thickness = size.width * 0.18
        let half = size.height / 2
        let span = size.width - (thickness * 2)
        let leg = half - (thickness * 1.35)
        let upper = thickness * 0.8
        let lower = half + (thickness * 0.45)

        return [
            CGRect(x: thickness, y: 0, width: span, height: thickness),
            CGRect(x: size.width - thickness, y: upper, width: thickness, height: leg),
            CGRect(x: size.width - thickness, y: lower, width: thickness, height: leg),
            CGRect(x: thickness, y: size.height - thickness, width: span, height: thickness),
            CGRect(x: 0, y: lower, width: thickness, height: leg),
            CGRect(x: 0, y: upper, width: thickness, height: leg),
            CGRect(x: thickness, y: half - (thickness / 2), width: span, height: thickness),
        ]
    }
}
