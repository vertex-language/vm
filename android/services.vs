package android

import (
    "vm/goldfish"
)

/// The emulator's qemud "boot-properties" service: Android's qemu-props
/// asks for the list once at boot and sets each property it is sent.
/// The list ends with a message holding a single NUL. Read-only
/// properties aren't sent; the ramdisk has them (BootProperties).
public final class BootPropertiesService: goldfish.QemudService {
    public let Properties: BootProperties

    public init(_ props: BootProperties) {
        Properties = props
    }

    public func Received(_ message: [uint8], from client: goldfish.QemudClient) {
        if string(decoding: message, as: UTF8.self) != "list" { return }
        for l in Properties.ServiceLines {
            client.Reply(l)
        }
        client.Reply(bytes: [0])
    }
}

/// The emulator's "logcat" pipe, which its images can write the device's
/// log to as text (logcat's androidboot.consolepipe=qemu_pipe,pipe:logcat).
/// Each whole line goes to OnLine; with none set, the log is taken and
/// dropped. (Android 9's PSR1 image's goldfish-logcat exits without
/// writing even when asked; vm doesn't ask yet.)
public final class LogcatService: goldfish.PipeService {
    public var OnLine: ((string) -> Void)? = nil

    public init() {}

    public func Open(_ args: string, waker: goldfish.Waker) -> (any goldfish.PipeConnection)? {
        return LogcatConnection(self)
    }
}

final class LogcatConnection: goldfish.PipeConnection {
    let service: LogcatService
    var partial: [uint8] = []
    var closed = false

    init(_ service: LogcatService) {
        self.service = service
    }

    func Send(_ bytes: [uint8]) -> goldfish.Transfer {
        if closed { return .closed }
        if bytes.isEmpty { return .again }
        if let f = service.OnLine {
            for b in bytes {
                if b == 0x0A {
                    f(string(decoding: partial, as: UTF8.self))
                    partial = []
                } else if b != 0 {
                    partial.append(b)
                }
            }
        }
        return .done(bytes.count)
    }

    func Receive(max: int) -> [uint8] { [] }
    var Closed: bool { closed }
    var Readable: bool { false }
    var Writable: bool { !closed }

    func Close() {
        closed = true
        if !partial.isEmpty, let f = service.OnLine { f(string(decoding: partial, as: UTF8.self)) }
        partial = []
    }
}
