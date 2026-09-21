// SPDX-License-Identifier: Apache-2.0
import Foundation
import CGaugeSMC

/// Typed access to the System Management Controller.
///
/// Multi-byte integer keys are little-endian on Apple Silicon and big-endian on
/// Intel. Verified against a Mac17,2: B0RM/B0FC decode to 6191/6254 mAh only
/// when read little-endian, which matches BRSC reporting 99%.
public final class SMC: @unchecked Sendable {
    public static let shared = SMC()

    private let lock = NSLock()
    private var isOpen = false

    private init() {}

    deinit { gauge_smc_close() }

    @discardableResult
    public func open() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !isOpen { isOpen = gauge_smc_open() }
        return isOpen
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        gauge_smc_close()
        isOpen = false
    }

    // MARK: Reading

    public struct Value: Sendable {
        public let type: String
        public let bytes: [UInt8]

        public init(type: String, bytes: [UInt8]) {
            self.type = type
            self.bytes = bytes
        }
    }

    public func read(_ key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen || gauge_smc_open() else { return nil }
        isOpen = true

        var raw = gauge_smc_value()
        guard key.withCString({ gauge_smc_read($0, &raw) }) else { return nil }

        let size = Int(raw.size)
        var bytes = [UInt8]()
        bytes.reserveCapacity(size)
        withUnsafeBytes(of: raw.bytes) { buffer in
            for i in 0..<min(size, buffer.count) { bytes.append(buffer[i]) }
        }
        return Value(type: Self.fourCharString(raw.type), bytes: bytes)
    }

    /// Reads a key and converts whatever format it uses into a Double.
    public func double(_ key: String) -> Double? {
        guard let value = read(key) else { return nil }
        return Self.decode(value)
    }

    public func int(_ key: String) -> Int? {
        double(key).map { Int($0.rounded()) }
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = read(key), let first = value.bytes.first else { return nil }
        return first != 0
    }

    // MARK: Writing

    /// Only meaningful for a handful of control keys (fan targets). The SMC
    /// rejects the write when the process lacks the privilege, which is the
    /// expected outcome for an unprivileged app.
    @discardableResult
    public func write(_ key: String, bytes: [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen || gauge_smc_open() else { return false }
        isOpen = true
        return key.withCString { keyPtr in
            bytes.withUnsafeBufferPointer { buf in
                gauge_smc_write(keyPtr, buf.baseAddress, UInt32(bytes.count))
            }
        }
    }

    // MARK: Enumeration

    public var keyCount: Int { Int(gauge_smc_key_count()) }

    /// Every key the SMC exposes. Used by the sensor browser in settings; it is
    /// slow (thousands of round trips) so callers should do it off the main
    /// thread and cache the result.
    public func allKeys() -> [String] {
        let count = gauge_smc_key_count()
        guard count > 0 else { return [] }
        var keys = [String]()
        keys.reserveCapacity(Int(count))
        var buffer = [CChar](repeating: 0, count: 5)
        for index in 0..<count {
            let ok = buffer.withUnsafeMutableBufferPointer { gauge_smc_key_at_index(index, $0.baseAddress!) }
            if ok, let key = String(validatingUTF8: buffer), key.count == 4 { keys.append(key) }
        }
        return keys
    }

    // MARK: Decoding

    public static func fourCharString(_ value: UInt32) -> String {
        let chars = [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
                     UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        return String(bytes: chars, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    public static func decode(_ value: Value) -> Double? {
        let b = value.bytes
        guard !b.isEmpty else { return nil }

        switch value.type {
        case "flt":
            guard b.count >= 4 else { return nil }
            return Double(Float(bitPattern: littleEndianWord(b)))

        case "ui8", "si8", "hex", "char", "flag":
            return value.type == "si8" ? Double(Int8(bitPattern: b[0])) : Double(b[0])

        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(unsignedInteger(b, width: 2))

        case "si16":
            guard b.count >= 2 else { return nil }
            return Double(Int16(truncatingIfNeeded: unsignedInteger(b, width: 2)))

        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(unsignedInteger(b, width: 4))

        case "si32":
            guard b.count >= 4 else { return nil }
            return Double(Int32(truncatingIfNeeded: unsignedInteger(b, width: 4)))

        // Legacy Intel fixed-point encodings, always big-endian.
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0

        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0

        case "fp1f", "fp4c", "fp5b", "fp6a", "fp79", "fp88", "fpa6", "fpc4", "fpe2 ":
            guard b.count >= 2 else { return nil }
            let fractionBits = Self.fixedPointFractionBits(value.type)
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / Double(1 << fractionBits)

        default:
            return nil
        }
    }

    private static func fixedPointFractionBits(_ type: String) -> Int {
        // "fpXY": X integer digits, Y fraction digits, both hex.
        guard type.count >= 4, let last = type.last, let bits = Int(String(last), radix: 16) else { return 0 }
        return bits
    }

    /// Apple Silicon stores multi-byte SMC integers little-endian; Intel big-endian.
    private static func unsignedInteger(_ bytes: [UInt8], width: Int) -> UInt32 {
        var result: UInt32 = 0
        #if arch(arm64)
        for i in stride(from: min(width, bytes.count) - 1, through: 0, by: -1) {
            result = (result << 8) | UInt32(bytes[i])
        }
        #else
        for i in 0..<min(width, bytes.count) {
            result = (result << 8) | UInt32(bytes[i])
        }
        #endif
        return result
    }

    private static func littleEndianWord(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
}
