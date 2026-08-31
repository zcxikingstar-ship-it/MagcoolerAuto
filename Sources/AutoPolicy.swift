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

struct TemperatureThresholds: Equatable {
    var off: Double
    var low: Double
    var medium: Double
    var high: Double

    static let standard = TemperatureThresholds(off: 55, low: 60, medium: 70, high: 80)

    var isValid: Bool {
        (0...120).contains(off) && off < low && low < medium && medium < high && high <= 120
    }
}

struct AutomationTimings: Equatable {
    var confirmationDelay: TimeInterval
    var shutdownDelay: TimeInterval
    var sampleInterval: TimeInterval

    static let standard = AutomationTimings(
        confirmationDelay: 10,
        shutdownDelay: 60,
        sampleInterval: 30
    )

    var isValid: Bool {
        (1...3600).contains(confirmationDelay) &&
        (1...3600).contains(shutdownDelay) &&
        (1...3600).contains(sampleInterval)
    }
}

struct AutoPolicy {
    private(set) var currentTarget: CoolingTarget = .off
    private(set) var pendingTarget: CoolingTarget?
    private(set) var thresholds: TemperatureThresholds
    private(set) var timings: AutomationTimings
    private var pendingSince: TimeInterval?
    private var lowSince: TimeInterval?

    init(
        thresholds: TemperatureThresholds = .standard,
        timings: AutomationTimings = .standard
    ) {
        self.thresholds = thresholds.isValid ? thresholds : .standard
        self.timings = timings.isValid ? timings : .standard
    }

    static func candidate(
        for temperature: Double,
        thresholds: TemperatureThresholds = .standard
    ) -> CoolingTarget? {
        if temperature >= thresholds.high { return .high }
        if temperature >= thresholds.medium { return .medium }
        if temperature >= thresholds.low { return .low }
        if temperature <= thresholds.off { return .off }
        return nil
    }

    mutating func updateThresholds(_ thresholds: TemperatureThresholds) {
        guard thresholds.isValid else { return }
        self.thresholds = thresholds
        cancelPending()
        lowSince = nil
    }

    mutating func updateTimings(_ timings: AutomationTimings) {
        guard timings.isValid else { return }
        self.timings = timings
        cancelPending()
        lowSince = nil
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
        if temperature <= thresholds.off {
            cancelPending()
            if lowSince == nil { lowSince = now }
            if now - (lowSince ?? now) >= timings.shutdownDelay, currentTarget != .off {
                currentTarget = .off
                lowSince = nil
                return .apply(.off)
            }
            return .none
        }

        lowSince = nil
        guard let candidate = Self.candidate(for: temperature, thresholds: thresholds), candidate != .off else {
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
           now - pendingSince >= timings.confirmationDelay {
            currentTarget = candidate
            cancelPending()
            return .apply(candidate)
        }

        if pendingTarget != candidate {
            pendingTarget = candidate
            pendingSince = now
            return .confirm(candidate, after: timings.confirmationDelay)
        }

        return .none
    }
}
