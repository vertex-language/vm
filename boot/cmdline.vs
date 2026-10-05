package boot

/// A kernel command line, built from parts. Values with spaces are quoted.
public struct Cmdline {
    var parts: [string] = []

    public init(_ base: string = "") {
        if !base.isEmpty {
            parts.append(base)
        }
    }

    public mutating func Add(_ flag: string) {
        parts.append(flag)
    }

    public mutating func Add(_ key: string, _ value: string) {
        if value.contains(" ") {
            parts.append("\(key)=\"\(value)\"")
        } else {
            parts.append("\(key)=\(value)")
        }
    }

    public var String: string {
        parts.joined(separator: " ")
    }
}
