import Foundation
import Darwin

/// Fallback transport: a `/dev/cu.*` node that macOS sometimes creates for paired SPP devices.
@MainActor
public final class SerialTransport: Transport {
    public weak var delegate: TransportDelegate?
    public let path: String
    public private(set) var isOpen = false
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String) { self.path = path }

    public var displayName: String { path }

    public func open() throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw TransportError.serial("open(\(path)) failed: \(String(cString: strerror(errno)))") }

        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200)) // ignored by Bluetooth SPP nodes, required by termios
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd); fd = -1
            throw TransportError.serial("tcsetattr failed: \(msg)")
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        src.resume()
        source = src
        isOpen = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.transportDidOpen(self)
            }
        }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 {
            delegate?.transport(self, didReceive: Array(buf[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            close()
        }
    }

    public func close() {
        source?.cancel()
        source = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        if isOpen {
            isOpen = false
            delegate?.transportDidClose(self)
        }
    }

    public func send(_ frame: [UInt8]) throws {
        try Allowlist.validate(frame)
        guard isOpen, fd >= 0 else { throw TransportError.notOpen }
        var offset = 0
        while offset < frame.count {
            let n = frame[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw TransportError.serial("write failed: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
    }
}
