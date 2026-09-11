#if os(macOS) && STABILITY
import Darwin
import Foundation

public enum StabilityDiagnosticTailError: Error {
    case replacedOrTruncated, unhealthyWriter
}

/// A run-local scheduling aid. Register before the UI action to avoid replaying
/// historical callbacks. Certification still validates the entire sealed bundle.
/// Use on one actor; this cursor deliberately does not conform to Sendable.
public final class StabilityDiagnosticTail {
    private let url: URL
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private var offset: Int
    private var anchor: Data
    private let decoder: JSONDecoder

    public init(eventsURL: URL) throws {
        let fd = Darwin.open(eventsURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
        do {
            try SecurePOSIXFile.requireRegularFile(fd)
            guard flock(fd, LOCK_SH) == 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
            defer { flock(fd, LOCK_UN) }
            var status = stat()
            guard fstat(fd, &status) == 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
            let baseline = try SecurePOSIXFile.read(fd, maximumBytes: StabilityRunCoordinator.defaultMaximumTotalBytes)
            let end = baseline.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            url = eventsURL
            descriptor = fd
            device = status.st_dev
            inode = status.st_ino
            offset = end
            anchor = Data(baseline[..<end].suffix(64))
            decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    /// Nonblocking shared lock: a busy writer is retried by the next local tick.
    /// Decode only new complete records, retaining any interrupted trailing line.
    public func readAvailable() throws -> [ProviderDiagnosticEvent] {
        guard SecurePOSIXFile.pathKind(url.deletingLastPathComponent()
            .appendingPathComponent("diagnostic-health.failed")) == .missing else {
            throw StabilityDiagnosticTailError.unhealthyWriter
        }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return [] }
            throw ProviderDiagnosticStoreError.fileSystemError(errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        var status = stat(), current = stat()
        guard fstat(descriptor, &status) == 0, lstat(url.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFREG, current.st_dev == device, current.st_ino == inode,
              status.st_size >= offset else { throw StabilityDiagnosticTailError.replacedOrTruncated }
        guard try read(count: anchor.count, at: offset - anchor.count) == anchor else {
            throw StabilityDiagnosticTailError.replacedOrTruncated
        }
        guard status.st_size <= StabilityRunCoordinator.defaultMaximumTotalBytes else {
            throw ProviderDiagnosticStoreError.fileTooLarge
        }
        let count = min(Int(status.st_size) - offset, 1_024 * 1_024)
        guard count > 0 else { return [] }
        let data = try read(count: count, at: offset)
        guard let newline = data.lastIndex(of: 0x0A) else {
            guard count < 1_024 * 1_024 else { throw ProviderDiagnosticStoreError.fileTooLarge }
            return []
        }
        let complete = Data(data[...newline])
        let events = try StabilityRunCoordinator.decodeDiagnosticEvents(from: complete, decoder: decoder)
        offset += complete.count
        anchor = try read(count: min(offset, 64), at: max(0, offset - 64))
        return events
    }

    private func read(count: Int, at offset: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var consumed = 0
            while consumed < count {
                let result = pread(descriptor, bytes.baseAddress!.advanced(by: consumed), count - consumed, off_t(offset + consumed))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ProviderDiagnosticStoreError.fileSystemError(errno) }
                consumed += result
            }
        }
        return data
    }
}
#endif
