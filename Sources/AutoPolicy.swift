import Foundation

enum CoolingTarget: Int, Equatable {
    case off = 0
    case low = 1
    case medium = 2
    case high = 3

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .low: return "低档"
        case .medium: return "中档"
        case .high: return "高档"
        }
    }
}

enum ControlMode: Int {
    case automatic = 0
    case forcedOn = 1
    case forcedOff = 2

    var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .forcedOn: return "强制开启"
        case .forcedOff: return "强制关闭"
        }
    }

    var forcedTarget: CoolingTarget? {
        switch self {
        case .automatic: return nil
        case .forcedOn: return .high
        case .forcedOff: return .off
        }
    }
}

enum PolicyAction: Equatable {
    case none
    case confirm(CoolingTarget, after: TimeInterval)
    case apply(CoolingTarget)
}

struct AutoPolicy {
    private(set) var currentTarget: CoolingTarget = .off
    private(set) var pendingTarget: CoolingTarget?
    private var pendingSince: TimeInterval?
    private var lowSince: TimeInterval?

    static func candidate(for temperature: Double) -> CoolingTarget? {
        if temperature >= 80 { return .high }
        if temperature >= 70 { return .medium }
        if temperature >= 60 { return .low }
        if temperature <= 55 { return .off }
        return nil
    }

    mutating func synchronizeCurrent(to target: CoolingTarget) {
        currentTarget = target
        cancelPending()
        lowSince = nil
    }

    mutating func cancelPending() {
        pendingTarget = nil
        pendingSince = nil
    }

    mutating func process(temperature: Double, at now: TimeInterval, confirmation: Bool = false) -> PolicyAction {
        if temperature <= 55 {
            cancelPending()
            if lowSince == nil { lowSince = now }
            if now - (lowSince ?? now) >= 60, currentTarget != .off {
                currentTarget = .off
                lowSince = nil
                return .apply(.off)
            }
            return .none
        }

        lowSince = nil
        guard let candidate = Self.candidate(for: temperature), candidate != .off else {
            cancelPending()
            return .none
        }

        if candidate == currentTarget {
            cancelPending()
            return .none
        }

        if confirmation,
           pendingTarget == candidate,
           let pendingSince,
           now - pendingSince >= 10 {
            currentTarget = candidate
            cancelPending()
            return .apply(candidate)
        }

        if pendingTarget != candidate {
            pendingTarget = candidate
            pendingSince = now
            return .confirm(candidate, after: 10)
        }

        return .none
    }
}
