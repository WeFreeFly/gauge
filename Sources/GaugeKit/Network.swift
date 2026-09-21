import Foundation
import Darwin
import SystemConfiguration

public struct InterfaceCounters: Sendable, Hashable {
    public var name: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var packetsIn: UInt64
    public var packetsOut: UInt64
    public var errorsIn: UInt64
    public var errorsOut: UInt64
}

public struct InterfaceInfo: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var ipv4: [String] = []
    public var ipv6: [String] = []
    public var macAddress: String?
    public var isPrimary: Bool = false
    public var isUp: Bool = false
}

public struct NetworkSnapshot: Sendable {
    public var downloadRate: Double = 0      // bytes/sec
    public var uploadRate: Double = 0
    public var totalIn: Double = 0           // bytes since boot
    public var totalOut: Double = 0
    /// Bytes moved since the app launched — the number worth watching on a metered link.
    public var sessionIn: Double = 0
    public var sessionOut: Double = 0
    public var interfaces: [InterfaceInfo] = []
    public var primaryInterface: String?
    public var publicIPv4: String?
    public var publicIPv6: String?
    public var peakDownload: Double = 0
    public var peakUpload: Double = 0
}

public final class NetworkMonitor: @unchecked Sendable {
    private var previousIn: UInt64?
    private var previousOut: UInt64?
    private var previousTimestamp: Date?
    private var baselineIn: UInt64?
    private var baselineOut: UInt64?
    private var peakDownload: Double = 0
    private var peakUpload: Double = 0
    private var cachedInterfaces: [InterfaceInfo] = []
    private var cachedPrimary: String?
    private var interfacesReadAt: Date?

    /// Byte counters are one cheap sysctl; resolving addresses and the
    /// localised service names costs twenty times as much and changes only
    /// when the network does.
    public var interfaceRefreshInterval: TimeInterval = 10

    /// Loopback and virtual interfaces would double-count local traffic;
    /// anpi/ap are Apple-internal links that carry no user traffic.
    private static let excludedPrefixes = [
        "lo", "gif", "stf", "bridge", "utun", "awdl", "llw", "ipsec",
        "anpi", "ap", "vmenet", "XHC", "pktap",
    ]

    public init() {}

    public func sample(live: Bool = true) -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()
        let counters = Self.interfaceCounters()

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        for counter in counters where !Self.isExcluded(counter.name) {
            totalIn &+= counter.bytesIn
            totalOut &+= counter.bytesOut
        }

        snapshot.totalIn = Double(totalIn)
        snapshot.totalOut = Double(totalOut)

        let now = Date()
        if let lastIn = previousIn, let lastOut = previousOut, let last = previousTimestamp {
            let elapsed = now.timeIntervalSince(last)
            if elapsed > 0 {
                snapshot.downloadRate = Double(totalIn &- lastIn).safeDivided(by: elapsed)
                snapshot.uploadRate = Double(totalOut &- lastOut).safeDivided(by: elapsed)
            }
        }
        previousIn = totalIn
        previousOut = totalOut
        previousTimestamp = now

        if baselineIn == nil { baselineIn = totalIn; baselineOut = totalOut }
        snapshot.sessionIn = Double(totalIn &- (baselineIn ?? totalIn))
        snapshot.sessionOut = Double(totalOut &- (baselineOut ?? totalOut))

        peakDownload = max(peakDownload, snapshot.downloadRate)
        peakUpload = max(peakUpload, snapshot.uploadRate)
        snapshot.peakDownload = peakDownload
        snapshot.peakUpload = peakUpload

        let stale = interfacesReadAt.map { now.timeIntervalSince($0) >= interfaceRefreshInterval } ?? true
        if live || stale || cachedInterfaces.isEmpty {
            cachedPrimary = Self.primaryInterfaceName()
            cachedInterfaces = Self.interfaceDetails(primary: cachedPrimary)
            interfacesReadAt = now
        }
        snapshot.primaryInterface = cachedPrimary
        snapshot.interfaces = cachedInterfaces
        return snapshot
    }

    public func resetSessionTotals() {
        baselineIn = previousIn
        baselineOut = previousOut
        peakDownload = 0
        peakUpload = 0
    }

    static func isExcluded(_ name: String) -> Bool {
        excludedPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: Counters

    /// Reads the kernel's per-interface byte counters via the routing socket.
    public static func interfaceCounters() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [] }

        var results: [InterfaceCounters] = []
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }

                if header.ifm_type == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        results.append(InterfaceCounters(
                            name: name,
                            bytesIn: info.ifm_data.ifi_ibytes,
                            bytesOut: info.ifm_data.ifi_obytes,
                            packetsIn: info.ifm_data.ifi_ipackets,
                            packetsOut: info.ifm_data.ifi_opackets,
                            errorsIn: info.ifm_data.ifi_ierrors,
                            errorsOut: info.ifm_data.ifi_oerrors
                        ))
                    }
                }
                offset += messageLength
            }
        }
        return results
    }

    // MARK: Addresses


    static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Gauge" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    public static func interfaceDetails(primary: String?) -> [InterfaceInfo] {
        var interfaces: [String: InterfaceInfo] = [:]

        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(addresses) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard !isExcluded(name), let addressPointer = current.pointee.ifa_addr else { continue }

            var entry = interfaces[name] ?? InterfaceInfo(
                name: name,
                displayName: friendlyName(for: name) ?? name,
                isPrimary: name == primary,
                isUp: current.pointee.ifa_flags & UInt32(IFF_UP) != 0
            )

            let family = addressPointer.pointee.sa_family
            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                // inet_ntop is a pure formatting call; getnameinfo goes through
                // the resolver machinery even with NI_NUMERICHOST and costs
                // around twenty times as much per address.
                if let address = Self.presentationAddress(addressPointer) {
                    if family == UInt8(AF_INET) {
                        entry.ipv4.append(address)
                    } else if !address.hasPrefix("fe80") {
                        // Link-local addresses are noise in a status readout.
                        entry.ipv6.append(address)
                    }
                }
            } else if family == UInt8(AF_LINK) {
                entry.macAddress = macAddress(from: addressPointer)
            }
            interfaces[name] = entry
        }

        // An interface with no address is not carrying anything worth listing.
        return interfaces.values
            .filter { !$0.ipv4.isEmpty || !$0.ipv6.isEmpty }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return lhs.name < rhs.name
            }
    }

    private static func presentationAddress(_ pointer: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch pointer.pointee.sa_family {
        case UInt8(AF_INET):
            var address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        case UInt8(AF_INET6):
            var address = pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        default:
            return nil
        }
        return String(cString: buffer)
    }

    private static func macAddress(from pointer: UnsafeMutablePointer<sockaddr>) -> String? {
        let link = pointer.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
        guard link.sdl_alen == 6 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 6)
        withUnsafeBytes(of: link.sdl_data) { raw in
            for i in 0..<6 { bytes[i] = raw[Int(link.sdl_nlen) + i] }
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Turns "en0" into "Wi-Fi" using the same service list System GaugeSettings shows.
    private static func friendlyName(for bsdName: String) -> String? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for interface in interfaces {
            if SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
                return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            }
        }
        return nil
    }
}

// MARK: - Public address lookup

/// Resolving the public address is the only part of the app that talks to the
/// network, so it is opt-in and the endpoint is configurable.
public actor PublicIPResolver {
    public struct Result: Sendable {
        public let ipv4: String?
        public let ipv6: String?
        public let fetchedAt: Date
    }

    private var cached: Result?
    private let minimumInterval: TimeInterval = 15 * 60

    public init() {}

    public func lookup(endpointV4: String, endpointV6: String?, force: Bool = false) async -> Result? {
        if !force, let cached, Date().timeIntervalSince(cached.fetchedAt) < minimumInterval {
            return cached
        }
        // Both lookups run concurrently; either may come back empty.
        async let v4 = Self.fetch(endpointV4)
        async let v6 = Self.fetchIfPresent(endpointV6)
        let result = Result(ipv4: await v4, ipv6: await v6, fetchedAt: Date())
        // Keep whatever was already known if the lookup came back empty.
        if result.ipv4 == nil && result.ipv6 == nil { return cached }
        cached = result
        return result
    }

    private static func fetchIfPresent(_ endpoint: String?) async -> String? {
        guard let endpoint else { return nil }
        return await fetch(endpoint)
    }

    private static func fetch(_ endpoint: String) async -> String? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > 64 ? nil : trimmed
    }
}
