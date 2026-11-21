import Foundation
import Network

/// Hosts that stay on the local network, the only place plain HTTP is
/// tolerated (it would send the Plex token unencrypted).
enum LocalNetwork {
    /// RFC 1918, carrier-grade NAT (Tailscale), loopback and IPv6 unique-local
    /// addresses. Hostnames never count.
    static func isPrivateAddress(_ host: String) -> Bool {
        let host = normalized(host)
        if let ipv4 = IPv4Address(host) {
            let bytes = [UInt8](ipv4.rawValue)
            switch (bytes[0], bytes[1]) {
            case (10, _), (127, _), (192, 168):
                return true
            case (172, let second):
                return (16...31).contains(second)
            case (100, let second):
                return (64...127).contains(second)
            default:
                return false
            }
        }
        if let ipv6 = IPv6Address(host) {
            return ipv6 == .loopback || [UInt8](ipv6.rawValue)[0] & 0xFE == 0xFC
        }
        return false
    }

    /// A private address, `localhost`, a `.local` (mDNS) name or a single-label
    /// name resolved by the local DNS search domain.
    static func isLocalHost(_ host: String) -> Bool {
        let host = normalized(host)
        guard !host.isEmpty else { return false }
        if isPrivateAddress(host) || host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        return !host.contains(".") && !host.contains(":")
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
}
