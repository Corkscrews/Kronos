import Foundation

/// A value that is only read and written while holding a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Runs `body` with exclusive access to the value.
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        self.lock.lock()
        defer { self.lock.unlock() }
        return try body(&self.value)
    }
}
