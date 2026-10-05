package hypervisor

/// HypervisorError is every way the host's hypervisor refuses.
public enum HypervisorError: Error, CustomStringConvertible {
    /// There's no hypervisor here: the platform has none, or this isn't a
    /// target it runs on (Intel Macs, Android apps).
    case unsupported(string)
    /// There is one and this process may not use it: the binary lacks the
    /// com.apple.security.hypervisor entitlement, the Windows Hypervisor
    /// Platform feature is off, or /dev/kvm isn't readable.
    case denied(string)
    /// macOS allows one VM per process, and this process has one.
    case busy(string)
    case noMemory(string)
    case invalidArgument(string)
    /// Anything else, with the number the platform reported.
    case system(code: int32, context: string)

    public var description: string {
        switch self {
        case .unsupported(let what):
            return "no hypervisor available: \(what)"
        case .denied(let what):
            return "hypervisor access denied: \(what)"
        case .busy(let what):
            return "hypervisor busy (one VM per process): \(what)"
        case .noMemory(let what):
            return "out of memory: \(what)"
        case .invalidArgument(let what):
            return "invalid argument: \(what)"
        case .system(let code, let what):
            return "hypervisor error \(code): \(what)"
        }
    }
}

func errorFor(_ code: int64, _ what: string) -> HypervisorError {
    switch int32(code) {
    case Code.unsupported:
        return .unsupported(what)
    case Code.denied:
        return .denied(what)
    case Code.busy:
        return .busy(what)
    case Code.noMemory:
        return .noMemory(what)
    case Code.invalid:
        return .invalidArgument(what)
    default:
        return .system(code: lastError(), context: what)
    }
}

func check(_ code: int32, _ what: string) throws {
    if code < 0 {
        throw errorFor(int64(code), what)
    }
}
