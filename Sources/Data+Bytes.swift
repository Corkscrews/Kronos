import Foundation

extension Data {

    /// Creates an Data instance based on a hex string (example: "ffff" would be <FF FF>).
    ///
    /// - parameter hex: The hex string without any spaces; should only have [0-9A-Fa-f].
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Data.nibble(digits[index]), let low = Data.nibble(digits[index + 1]) else {
                return nil
            }

            bytes.append(high << 4 | low)
        }

        self.init(bytes)
    }

    /// Gets a big-endian integer from the given offset.
    ///
    /// - parameter type:   The integer type to be read.
    /// - parameter offset: The offset of the integer, counted from the first byte of the receiver (also for
    ///                     slices). Note that `offset + MemoryLayout<T>.size` should never be > count.
    ///
    /// - returns: The integer located at `offset`, in host byte order.
    func bigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        precondition(offset >= 0 && offset <= self.count - MemoryLayout<T>.size, "Read past the end of Data")
        return self.withUnsafeBytes { buffer in
            T(bigEndian: buffer.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }

    /// Appends the given integer into the receiver Data in big-endian (network) order.
    ///
    /// - parameter value: The integer to be appended.
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { self.append(contentsOf: $0) }
    }

    /// Value of one ASCII hex digit, or `nil` when `digit` is not [0-9A-Fa-f].
    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return digit - UInt8(ascii: "0")

        case UInt8(ascii: "a") ... UInt8(ascii: "f"):
            return digit - UInt8(ascii: "a") + 10

        case UInt8(ascii: "A") ... UInt8(ascii: "F"):
            return digit - UInt8(ascii: "A") + 10

        default:
            return nil
        }
    }
}
