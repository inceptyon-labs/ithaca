import Foundation

/// The device's RAM, in the three sizes Ithaca's targets ship with. Cache
/// budgets scale with it: tvOS 26 still runs on the 2 GB Apple TV HD, where
/// budgets sized for a 4 GB Apple TV 4K leave too little for a 4K decode.
enum DeviceMemoryClass: Sendable, Equatable {
    /// 2 GB: Apple TV HD.
    case small
    /// 3 GB: Apple TV 4K (1st and 2nd generation), older iPhones and iPads.
    case medium
    /// 4 GB and more.
    case large

    static let current = DeviceMemoryClass(physicalMemory: ProcessInfo.processInfo.physicalMemory)

    /// Devices report a little less than their nominal size, so the
    /// boundaries sit halfway between sizes.
    init(physicalMemory: UInt64) {
        let halfGigabyte: UInt64 = 1 << 29
        switch physicalMemory {
        case ..<(5 * halfGigabyte): self = .small
        case ..<(7 * halfGigabyte): self = .medium
        default: self = .large
        }
    }
}
