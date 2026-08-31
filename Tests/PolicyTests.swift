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
