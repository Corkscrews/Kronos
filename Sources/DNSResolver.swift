import Foundation

private let kCopyNoOperation = unsafeBitCast(0, to: CFAllocatorCopyDescriptionCallBack.self)
private let kDefaultTimeout = 8.0

/// One DNS lookup, scheduled on the main run loop.
@MainActor
final class DNSResolver {
    private let host: CFHost
    private var continuation: CheckedContinuation<[InternetAddress], Never>?
    private var timeout: Task<Void, Never>?

    private init(host: String) {
        self.host = CFHostCreateWithName(kCFAllocatorDefault, host as CFString).takeRetainedValue()
    }

    /// Performs DNS lookups and returns the answers from the name server(s) that were queried.
    ///
    /// - parameter host:    The host to be looked up.
    /// - parameter timeout: The connection timeout.
    /// - returns: The resolved addresses. Empty on failure, timeout or cancellation.
    static func resolve(host: String, timeout: TimeInterval = kDefaultTimeout) async -> [InternetAddress] {
        let resolver = DNSResolver(host: host)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolver.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in resolver.finish([]) }
        }
    }

    private func start(timeout: TimeInterval, continuation: CheckedContinuation<[InternetAddress], Never>) {
        self.continuation = continuation

        let callback: CFHostClientCallBack = { host, _, _, info in
            guard let info = info else {
                return
            }

            let resolver = Unmanaged<DNSResolver>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { resolver.finish(DNSResolver.addresses(of: host)) }
        }

        // `resolve` keeps the resolver alive until `finish` detaches this client.
        var clientContext = CFHostClientContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                retain: nil, release: nil, copyDescription: kCopyNoOperation)
        CFHostSetClient(self.host, callback, &clientContext)
        CFHostScheduleWithRunLoop(self.host, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        CFHostStartInfoResolution(self.host, .addresses, nil)

        self.timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            self?.finish([])
        }
    }

    /// Stops the lookup and returns `addresses`. Only the first call has an effect.
    private func finish(_ addresses: [InternetAddress]) {
        guard let continuation = self.continuation else {
            return
        }

        self.continuation = nil
        self.timeout?.cancel()
        CFHostCancelInfoResolution(self.host, .addresses)
        CFHostUnscheduleFromRunLoop(self.host, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        CFHostSetClient(self.host, nil, nil)
        continuation.resume(returning: addresses)
    }

    private nonisolated static func addresses(of host: CFHost) -> [InternetAddress] {
        var resolved: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(host, &resolved), resolved.boolValue else {
            return []
        }

        return (addresses.takeUnretainedValue() as NSArray)
            .compactMap { $0 as? NSData }
            .compactMap(InternetAddress.init)
    }
}
