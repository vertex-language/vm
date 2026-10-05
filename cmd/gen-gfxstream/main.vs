// gen-gfxstream writes vm/gfxstream/signatures.vs from the protocol's
// spec files in vm/gfxstream/spec: for each call the guest's encoder can
// send, its opcode, name, how each parameter travels on the wire, and the
// size of its result.
//
// The .in files give each call's C signature, in opcode order from the
// .attrib file's base_opcode; the .attrib files say which pointer
// parameters are outputs, and the .types files each type's width.
//
//     vsc run gen-gfxstream        (from vm/)
package main

import (
    "fs"
)

struct Param {
    var kind: string   // "value", "input", "output", "inout"
    var bytes: int
}

struct Entry {
    var op: int
    var name: string
    var params: [Param]
    var result: int
}

func readText(_ path: string) throws -> string {
    string(decoding: try fs.ReadFile(fs.Path(path)), as: UTF8.self)
}

func trim(_ s: string) -> string {
    var b = Array(s.utf8)
    while let f = b.first, f == 0x20 || f == 0x09 || f == 0x0d { b.removeFirst() }
    while let l = b.last, l == 0x20 || l == 0x09 || l == 0x0d { b.removeLast() }
    return string(decoding: b, as: UTF8.self)
}

/// "GLenum 32 0x%08x" lines: a type's width in bits.
func readTypes(_ path: string) throws -> [string: int] {
    var out: [string: int] = [:]
    for line in try readText(path).split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map { string($0) }
        if f.count >= 2, let bits = int(f[1]) {
            out[f[0]] = bits
        }
    }
    return out
}

/// The .attrib file: its base_opcode, and each call's pointer parameters
/// that aren't inputs (name → param → "out"/"inout").
func readAttrib(_ path: string) throws -> (int, [string: [string: string]]) {
    var base = -1
    var out: [string: [string: string]] = [:]
    var current = ""
    for raw in try readText(path).split(separator: "\n") {
        let line = string(raw)
        if line.hasPrefix("#") || trim(line).isEmpty { continue }
        if !(line.hasPrefix(" ") || line.hasPrefix("\t")) {
            current = trim(line)
            continue
        }
        let spaced = string(decoding: Array(trim(line).utf8).map { $0 == 0x09 ? 0x20 : $0 }, as: UTF8.self)   // vsc_TODO #44
        let f = spaced.split(separator: " ", omittingEmptySubsequences: true).map { string($0) }
        if f.count >= 2 && f[0] == "base_opcode", let n = int(f[1]) {
            base = n
        }
        if f.count >= 3 && f[0] == "dir" {
            var d = out[current] ?? [:]
            d[f[1]] = f[2]
            out[current] = d
        }
    }
    if base < 0 { throw GenError.malformed(path + ": no base_opcode") }
    return (base, out)
}

/// A parameter's type, without `const` and spaces: "const GLchar* name" → "GLchar*".
func paramType(_ decl: string) -> (string, string) {
    var text = trim(decl)
    // The name is the last identifier; everything before it is the type.
    var b = Array(text.utf8)
    var end = b.count
    while end > 0 && (isIdent(b[end - 1])) { end -= 1 }
    let name = string(decoding: b[end...], as: UTF8.self)
    text = string(decoding: b[0..<end], as: UTF8.self)
    var t = ""
    for word in text.split(separator: " ", omittingEmptySubsequences: true) where word != "const" {
        t += string(word)
    }
    b = Array(t.utf8)
    var clean: [uint8] = []
    for c in b where c != 0x20 { clean.append(c) }
    return (string(decoding: clean, as: UTF8.self), name)
}

func isIdent(_ c: uint8) -> bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f
}

func widthOf(_ type: string, _ types: [string: int]) throws -> int {
    if type == "void" { return 0 }
    if type == "int" { return 4 }   // C's int, which the .types files leave out
    guard let bits = types[type] else { throw GenError.unknownType(type) }
    return bits / 8
}

enum GenError: Error {
    case unknownType(string)
    case malformed(string)
}

func readApi(_ dir: string, _ base: string) throws -> [Entry] {
    let types = try readTypes(dir + "/" + base + ".types")
    let (first, dirs) = try readAttrib(dir + "/" + base + ".attrib")
    var out: [Entry] = []
    for raw in try readText(dir + "/" + base + ".in").split(separator: "\n") {
        let line = trim(string(raw))
        // GL_ENTRY(ret, name, params...); the renderControl spec spells one GL_ENRTY.
        guard line.hasPrefix("GL_ENTRY(") || line.hasPrefix("GL_ENRTY("),
              let close = line.lastIndex(of: ")") else { continue }
        let inner = string(line[line.index(line.startIndex, offsetBy: 9)..<close])
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false).map { trim(string($0)) }
        if parts.count < 2 { throw GenError.malformed(line) }
        let name = parts[1]
        let op = first + out.count
        var params: [Param] = []
        for decl in parts.dropFirst(2) where !decl.isEmpty && decl != "void" {
            let (t, pname) = paramType(decl)
            if t.hasSuffix("*") {
                let d = dirs[name]?[pname] ?? "in"
                params.append(Param(kind: d == "out" ? "output" : d == "inout" ? "inout" : "input", bytes: 0))
            } else {
                params.append(Param(kind: "value", bytes: try widthOf(t, types)))
            }
        }
        let (rt, _) = paramType(parts[0] + " x")
        out.append(Entry(op: op, name: name, params: params, result: rt.hasSuffix("*") ? 4 : try widthOf(rt, types)))
    }
    return out
}

func render(_ entries: [Entry], as varName: string) -> string {
    var s = "/// \(entries.count) calls, by opcode.\nlet \(varName): [Signature] = [\n"
    for e in entries {
        var ps: [string] = []
        for p in e.params {
            switch p.kind {
            case "value": ps.append(".value(\(p.bytes))")
            case "output": ps.append(".output")
            case "inout": ps.append(".inputOutput")
            default: ps.append(".input")
            }
        }
        s += "    Signature(op: \(e.op), name: \"\(e.name)\", params: [\(ps.joined(separator: ", "))], result: \(e.result)),\n"
    }
    return s + "]\n"
}

func main() -> int32 {
    let dir = "gfxstream/spec"
    do {
        var text = "// Code generated by vm/cmd/gen-gfxstream from gfxstream/spec. DO NOT EDIT.\n\npackage gfxstream\n\n"
        text += render(try readApi(dir, "renderControl"), as: "renderControlSignatures") + "\n"
        text += render(try readApi(dir, "gles1"), as: "gles1Signatures") + "\n"
        text += render(try readApi(dir, "gles2"), as: "gles2Signatures")
        try fs.WriteFile(fs.Path("gfxstream/signatures.vs"), Array(text.utf8))
        print("wrote gfxstream/signatures.vs")
        return 0
    } catch {
        print("gen-gfxstream: \(error)")
        return 1
    }
}
