package vm

/// VmError is an error during machine creation, configuration, or execution.
public enum VmError: Error, CustomStringConvertible {
    case hypervisorUnavailable(string)
    case memoryAllocationFailed(string)
    case bootFailed(string)
    case deviceError(string)
    case invalidConfig(string)
    case crashed(string)

    public var description: string {
        switch self {
        case .hypervisorUnavailable(let s): return "hypervisor unavailable: \(s)"
        case .memoryAllocationFailed(let s): return "guest memory allocation failed: \(s)"
        case .bootFailed(let s): return "boot failed: \(s)"
        case .deviceError(let s): return "device error: \(s)"
        case .invalidConfig(let s): return "invalid configuration: \(s)"
        case .crashed(let s): return "guest crashed: \(s)"
        }
    }
}
