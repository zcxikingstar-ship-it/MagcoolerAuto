import Foundation

@main
private struct PolicyTests {
    private static var failures = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        expect(AutoPolicy.candidate(for: 59.9) == nil, "60°C 以下应保持")
        expect(AutoPolicy.candidate(for: 60) == .low, "60°C 应为低档")
        expect(AutoPolicy.candidate(for: 70) == .medium, "70°C 应为中档")
        expect(AutoPolicy.candidate(for: 80) == .high, "80°C 应为高档")

        let custom = TemperatureThresholds(off: 50, low: 65, medium: 75, high: 85)
        expect(custom.isValid, "递增的自定义阈值应有效")
        expect(!TemperatureThresholds(off: 65, low: 60, medium: 70, high: 80).isValid, "关闭温度不得高于低档")
        expect(AutoPolicy.candidate(for: 64.9, thresholds: custom) == nil, "自定义低档以下应保持")
        expect(AutoPolicy.candidate(for: 65, thresholds: custom) == .low, "应使用自定义低档阈值")
        expect(AutoPolicy.candidate(for: 75, thresholds: custom) == .medium, "应使用自定义中档阈值")
        expect(AutoPolicy.candidate(for: 85, thresholds: custom) == .high, "应使用自定义高档阈值")

        let customTimings = AutomationTimings(confirmationDelay: 5, shutdownDelay: 20, sampleInterval: 15)
        expect(customTimings.isValid, "有效的自定义时间应通过校验")
        expect(!AutomationTimings(confirmationDelay: 0, shutdownDelay: 20, sampleInterval: 15).isValid, "时间不得小于1秒")

        var policy = AutoPolicy()
        expect(policy.process(temperature: 80, at: 0) == .confirm(.high, after: 10), "高档应先确认")
        expect(policy.process(temperature: 80, at: 9, confirmation: true) == .none, "未满10秒不得切档")
        expect(policy.process(temperature: 80, at: 10, confirmation: true) == .apply(.high), "满10秒应切高档")

        policy.synchronizeCurrent(to: .off)
        _ = policy.process(temperature: 70, at: 20)
        policy.cancelPending()
        expect(policy.process(temperature: 70, at: 50) == .confirm(.medium, after: 10), "确认失败清理后应允许重新确认")

        policy.synchronizeCurrent(to: .high)
        expect(policy.process(temperature: 55, at: 100) == .none, "低温首次不关闭")
        expect(policy.process(temperature: 55, at: 159) == .none, "低温未满60秒不关闭")
        expect(policy.process(temperature: 55, at: 160) == .apply(.off), "低温满60秒关闭")

        policy.synchronizeCurrent(to: .medium)
        _ = policy.process(temperature: 55, at: 200)
        _ = policy.process(temperature: 56, at: 240)
        _ = policy.process(temperature: 55, at: 250)
        expect(policy.process(temperature: 55, at: 300) == .none, "中途高于55应重置低温计时")
        expect(policy.process(temperature: 55, at: 310) == .apply(.off), "重置后重新满60秒才关闭")

        policy = AutoPolicy(thresholds: custom)
        policy.synchronizeCurrent(to: .high)
        expect(policy.process(temperature: 55, at: 400) == .none, "高于自定义关闭温度不应开始关闭")
        expect(policy.process(temperature: 50, at: 410) == .none, "自定义关闭温度首次不关闭")
        expect(policy.process(temperature: 50, at: 470) == .apply(.off), "自定义关闭温度持续60秒应关闭")

        policy = AutoPolicy()
        _ = policy.process(temperature: 80, at: 500)
        policy.updateThresholds(custom)
        expect(policy.process(temperature: 80, at: 505) == .confirm(.medium, after: 10), "修改阈值后应清除旧确认并按新规则判断")

        policy = AutoPolicy(timings: customTimings)
        expect(policy.process(temperature: 80, at: 600) == .confirm(.high, after: 5), "应使用自定义确认时间")
        expect(policy.process(temperature: 80, at: 604, confirmation: true) == .none, "自定义确认时间未满不得切档")
        expect(policy.process(temperature: 80, at: 605, confirmation: true) == .apply(.high), "自定义确认时间已满应切档")
        expect(policy.process(temperature: 55, at: 610) == .none, "自定义关闭等待首次不关闭")
        expect(policy.process(temperature: 55, at: 630) == .apply(.off), "达到自定义关闭等待应关闭")

        expect(ControlMode.forcedOn.forcedTarget == .high, "强制开启应固定高档")
        expect(ControlMode.forcedOff.forcedTarget == .off, "强制关闭应固定关闭")
        expect(ControlMode.automatic.forcedTarget == nil, "自动模式无强制目标")

        if failures == 0 {
            print("All policy tests passed")
        } else {
            exit(1)
        }
    }
}
