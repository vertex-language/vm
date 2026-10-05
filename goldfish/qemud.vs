package goldfish

import (
    "sync"
)

/// A qemud service: small request-and-answer services (boot properties,
/// sensors, hw-control) that Android reaches as "pipe:qemud:<name>".
/// Messages each way are framed as four hex digits of length, then the
/// payload (device/generic/goldfish's qemud.h).
public protocol QemudService: AnyObject {
    /// A message from the guest; answers go through `client.Reply`.
    func Received(_ message: [uint8], from client: QemudClient)
}

/// Serves a QemudService on the pipe.
public final class QemudPipe: PipeService {
    let service: any QemudService

    public init(_ service: any QemudService) {
        self.service = service
    }

    public func Open(_ args: string, waker: Waker) -> (any PipeConnection)? {
        QemudClient(service: service, waker: waker)
    }
}

/// One guest's connection to a qemud service.
public final class QemudClient: PipeConnection {
    let service: any QemudService
    let waker: Waker
    let lock = sync.Mutex()
    var incoming: [uint8] = []
    var outgoing: [uint8] = []
    var closed = false

    init(service: any QemudService, waker: Waker) {
        self.service = service
        self.waker = waker
    }

    /// Queues a message for the guest.
    public func Reply(bytes message: [uint8]) {
        let header = Array(hex4(message.count).utf8)
        lock.withLock { outgoing += header + message }
        waker.Readable()
    }

    /// Queues a text message for the guest.
    public func Reply(_ text: string) {
        Reply(bytes: Array(text.utf8))
    }

    public func Send(_ bytes: [uint8]) -> Transfer {
        var messages: [[uint8]] = []
        lock.withLock {
            incoming += bytes
            while incoming.count >= 4 {
                guard let n = parseHex4(incoming) else {
                    // Not a frame header: the guest is confused; drop what it sent.
                    incoming = []
                    break
                }
                if incoming.count < 4 + n { break }
                messages.append(Array(incoming[4..<4 + n]))
                incoming.removeFirst(4 + n)
            }
        }
        for m in messages {
            service.Received(m, from: self)
        }
        return .done(bytes.count)
    }

    public func Receive(max: int) -> [uint8] {
        lock.withLock {
            let n = min(max, outgoing.count)
            let out = Array(outgoing[0..<n])
            outgoing.removeFirst(n)
            return out
        }
    }

    public var Closed: bool { lock.withLock { closed } }
    public var Readable: bool { lock.withLock { !outgoing.isEmpty } }
    public var Writable: bool { true }

    public func Close() {
        lock.withLock { closed = true }
    }
}

func hex4(_ n: int) -> string {
    let digits = Array("0123456789abcdef".utf8)
    var b: [uint8] = []
    for shift in [12, 8, 4, 0] {
        b.append(digits[(n >> shift) & 0xf])
    }
    return string(decoding: b, as: UTF8.self)
}

func parseHex4(_ b: [uint8]) -> int? {
    var n = 0
    for i in 0..<4 {
        let c = b[i]
        var d = 0
        if c >= 0x30 && c <= 0x39 {
            d = int(c - 0x30)
        } else if c >= 0x61 && c <= 0x66 {
            d = int(c - 0x61) + 10
        } else if c >= 0x41 && c <= 0x46 {
            d = int(c - 0x41) + 10
        } else {
            return nil
        }
        n = n * 16 + d
    }
    return n
}
