import AppKit
import CoreBluetooth
import Foundation

final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: "D52082AD-E805-9F97-9D4E-1C682D9C9CE6")
    private let powerUUID = CBUUID(string: "00001011-0000-1000-8000-00805F9B34FB")
    private let levelUUID = CBUUID(string: "00001012-0000-1000-8000-00805F9B34FB")
    private let lightUUID = CBUUID(string: "00001013-0000-1000-8000-00805F9B34FB")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var powerCharacteristic: CBCharacteristic?
    private var levelCharacteristic: CBCharacteristic?
    private var lightCharacteristic: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?

    private(set) var desiredTarget: CoolingTarget = .off
    private(set) var isSearchEnabled: Bool
    private var desiredLight: [UInt8]?

    var onStatus: ((String) -> Void)?
    var onTarget: ((CoolingTarget) -> Void)?

    override init() {
        isSearchEnabled = UserDefaults.standard.object(forKey: "bluetoothSearchEnabled") as? Bool ?? false
        super.init()
        if isSearchEnabled { createCentralManagerIfNeeded() }
    }

    private func createCentralManagerIfNeeded() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    func setSearchEnabled(_ enabled: Bool) {
        isSearchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "bluetoothSearchEnabled")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        if enabled {
            createCentralManagerIfNeeded()
            reconnect()
        } else {
            if central?.isScanning == true { central?.stopScan() }
            if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
                central?.cancelPeripheralConnection(peripheral)
            }
            powerCharacteristic = nil
            levelCharacteristic = nil
            lightCharacteristic = nil
            report("蓝牙搜索已关闭")
        }
    }

    func reconnect() {
        reconnectWorkItem?.cancel()
        guard isSearchEnabled else {
            report("蓝牙搜索已关闭")
            return
        }
        guard let central else { return }
        guard central.state == .poweredOn else {
            report("等待蓝牙开启")
            return
        }
        powerCharacteristic = nil
        levelCharacteristic = nil
        lightCharacteristic = nil
        if let peripheral, peripheral.state != .connected {
            report("正在重新连接…")
            central.connect(peripheral)
        } else if peripheral?.state == .connected {
            peripheral?.discoverServices([serviceUUID])
        } else {
            startScan()
        }
    }

    func setTarget(_ target: CoolingTarget) {
        desiredTarget = target
        onTarget?(target)
        restoreDesiredState()
    }

    func setLight(_ bytes: [UInt8]) {
        desiredLight = bytes
        guard isSearchEnabled else {
            report("灯效已保存，开启蓝牙搜索后恢复")
            return
        }
        guard let characteristic = lightCharacteristic else {
            report("灯效已保存，连接后恢复")
            return
        }
        write(bytes, to: characteristic)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if isSearchEnabled { reconnect() } else { report("蓝牙搜索已关闭") }
        case .poweredOff: report("蓝牙已关闭")
        case .unauthorized: report("没有蓝牙权限")
        case .unsupported: report("此 Mac 不支持蓝牙")
        default: report("正在初始化蓝牙…")
        }
    }

    private func startScan() {
        guard isSearchEnabled, let central, !central.isScanning else { return }
        report("正在搜索 Redmagic Magcooler…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isSearchEnabled else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? ""
        guard name.localizedCaseInsensitiveContains("Redmagic Magcooler") else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        report("发现设备，正在连接…")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isSearchEnabled else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        reconnectWorkItem?.cancel()
        report("已连接，正在读取控制通道…")
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        report("连接失败，准备重试")
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        powerCharacteristic = nil
        levelCharacteristic = nil
        lightCharacteristic = nil
        if isSearchEnabled {
            report("蓝牙已断开，准备重连")
            scheduleReconnect()
        } else {
            report("蓝牙搜索已关闭")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            report("未找到散热器服务，准备重试")
            scheduleReconnect()
            return
        }
        peripheral.discoverCharacteristics([powerUUID, levelUUID, lightUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            report("读取控制通道失败")
            scheduleReconnect()
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case powerUUID: powerCharacteristic = characteristic
            case levelUUID: levelCharacteristic = characteristic
            case lightUUID: lightCharacteristic = characteristic
            default: break
            }
        }
        guard powerCharacteristic != nil, levelCharacteristic != nil else {
            report("散热器控制通道不完整")
            return
        }
        report("散热器已就绪")
        restoreDesiredState()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { report("发送控制指令失败：\(error.localizedDescription)") }
    }

    private func restoreDesiredState() {
        guard isSearchEnabled, let powerCharacteristic else { return }
        let powerValue: UInt8 = desiredTarget == .off ? 3 : 2
        write([powerValue], to: powerCharacteristic)

        if desiredTarget != .off, let levelCharacteristic {
            let level = UInt8(desiredTarget.rawValue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak levelCharacteristic] in
                guard let self, let levelCharacteristic else { return }
                self.write([level], to: levelCharacteristic)
            }
        }
        if let desiredLight, let lightCharacteristic {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak lightCharacteristic] in
                guard let self, let lightCharacteristic else { return }
                self.write(desiredLight, to: lightCharacteristic)
            }
        }
    }

    private func write(_ bytes: [UInt8], to characteristic: CBCharacteristic) {
        guard let peripheral, peripheral.state == .connected else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
    }

    private func scheduleReconnect() {
        guard isSearchEnabled else { return }
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconnect() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }
}

final class TemperatureAutomation {
    private let ble: BLEManager
    private var policy: AutoPolicy
    private var regularTimer: Timer?
    private var confirmationTimer: Timer?
    private var displayTimer: Timer?
    private var nextRegularSample: Date?
    private var confirmationDue: Date?

    private(set) var mode: ControlMode
    var onTemperature: ((Double?) -> Void)?
    var onTiming: ((String) -> Void)?
    var onAutomationStatus: ((String) -> Void)?

    init(ble: BLEManager) {
        self.ble = ble
        let defaults = UserDefaults.standard
        mode = ControlMode(rawValue: defaults.integer(forKey: "controlMode")) ?? .automatic
        let savedThresholds = TemperatureThresholds(
            off: defaults.object(forKey: "thresholdOff") as? Double ?? TemperatureThresholds.standard.off,
            low: defaults.object(forKey: "thresholdLow") as? Double ?? TemperatureThresholds.standard.low,
            medium: defaults.object(forKey: "thresholdMedium") as? Double ?? TemperatureThresholds.standard.medium,
            high: defaults.object(forKey: "thresholdHigh") as? Double ?? TemperatureThresholds.standard.high
        )
        let savedTimings = AutomationTimings(
            confirmationDelay: defaults.object(forKey: "confirmationDelay") as? Double ?? AutomationTimings.standard.confirmationDelay,
            shutdownDelay: defaults.object(forKey: "shutdownDelay") as? Double ?? AutomationTimings.standard.shutdownDelay,
            sampleInterval: defaults.object(forKey: "sampleInterval") as? Double ?? AutomationTimings.standard.sampleInterval
        )
        policy = AutoPolicy(thresholds: savedThresholds, timings: savedTimings)
    }

    var thresholds: TemperatureThresholds { policy.thresholds }
    var timings: AutomationTimings { policy.timings }

    func start() {
        scheduleRegularTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshDisplay()
        }
        applyMode(sampleImmediately: true)
    }

    func stop() {
        regularTimer?.invalidate()
        confirmationTimer?.invalidate()
        displayTimer?.invalidate()
    }

    func setMode(_ mode: ControlMode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "controlMode")
        applyMode(sampleImmediately: true)
    }

    func setThresholds(_ thresholds: TemperatureThresholds) -> Bool {
        guard thresholds.isValid else { return false }
        policy.updateThresholds(thresholds)
        let defaults = UserDefaults.standard
        defaults.set(thresholds.off, forKey: "thresholdOff")
        defaults.set(thresholds.low, forKey: "thresholdLow")
        defaults.set(thresholds.medium, forKey: "thresholdMedium")
        defaults.set(thresholds.high, forKey: "thresholdHigh")
        if mode == .automatic { sample(confirmation: false) }
        return true
    }

    func setTimings(_ timings: AutomationTimings) -> Bool {
        guard timings.isValid else { return false }
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationDue = nil
        policy.updateTimings(timings)
        let defaults = UserDefaults.standard
        defaults.set(timings.confirmationDelay, forKey: "confirmationDelay")
        defaults.set(timings.shutdownDelay, forKey: "shutdownDelay")
        defaults.set(timings.sampleInterval, forKey: "sampleInterval")
        scheduleRegularTimer()
        if mode == .automatic { sample(confirmation: false) }
        return true
    }

    private func applyMode(sampleImmediately: Bool) {
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationDue = nil
        policy.synchronizeCurrent(to: ble.desiredTarget)

        if let target = mode.forcedTarget {
            ble.setTarget(target)
            onAutomationStatus?(target == .high ? "强制开启：高档" : "强制关闭")
        } else if sampleImmediately {
            sample(confirmation: false)
        }
        updateTimingDisplay()
    }

    private func scheduleRegularTimer() {
        regularTimer?.invalidate()
        let interval = policy.timings.sampleInterval
        nextRegularSample = Date().addingTimeInterval(interval)
        regularTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.nextRegularSample = Date().addingTimeInterval(self.policy.timings.sampleInterval)
            self.sample(confirmation: false)
        }
    }

    private func sample(confirmation: Bool) {
        let temperature = mc_cpu_average_temperature()
        guard temperature.isFinite else {
            onTemperature?(nil)
            onAutomationStatus?("无法读取 CPU 温度，本次不发送指令")
            if confirmation {
                policy.cancelPending()
                confirmationDue = nil
                confirmationTimer = nil
            }
            return
        }

        onTemperature?(temperature)
        guard mode == .automatic else { return }
        if confirmation { confirmationDue = nil }
        let action = policy.process(
            temperature: temperature,
            at: Date().timeIntervalSinceReferenceDate,
            confirmation: confirmation
        )
        handle(action)
    }

    private func refreshDisplay() {
        let temperature = mc_cpu_average_temperature()
        onTemperature?(temperature.isFinite ? temperature : nil)
        updateTimingDisplay()
    }

    private func handle(_ action: PolicyAction) {
        switch action {
        case .none:
            if let pending = policy.pendingTarget {
                onAutomationStatus?("等待确认：\(pending.displayName)")
            } else {
                onAutomationStatus?("自动监控中")
            }
        case let .confirm(target, delay):
            confirmationTimer?.invalidate()
            confirmationDue = Date().addingTimeInterval(delay)
            onAutomationStatus?("温度达到\(target.displayName)阈值，\(formatSeconds(delay))后确认")
            confirmationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.confirmationTimer = nil
                self?.sample(confirmation: true)
            }
        case let .apply(target):
            confirmationTimer?.invalidate()
            confirmationTimer = nil
            confirmationDue = nil
            ble.setTarget(target)
            onAutomationStatus?(target == .off ? "低温持续 \(formatSeconds(policy.timings.shutdownDelay))，已关闭制冷" : "自动切换到\(target.displayName)")
        }
        updateTimingDisplay()
    }

    private func updateTimingDisplay() {
        if let confirmationDue {
            let seconds = max(0, Int(ceil(confirmationDue.timeIntervalSinceNow)))
            onTiming?("确认采样：\(seconds) 秒后")
        } else if let nextRegularSample {
            let seconds = max(0, Int(ceil(nextRegularSample.timeIntervalSinceNow)))
            onTiming?("下次常规采样：\(seconds) 秒后")
        } else {
            onTiming?("等待采样")
        }
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        value.rounded() == value ? "\(Int(value)) 秒" : String(format: "%.1f 秒", value)
    }
}

final class ControllerViewController: NSViewController {
    private let ble: BLEManager
    private let automation: TemperatureAutomation

    private let temperatureLabel = NSTextField(labelWithString: "-- °C")
    private let bluetoothLabel = NSTextField(labelWithString: "正在初始化蓝牙…")
    private let targetLabel = NSTextField(labelWithString: "目标制冷：关闭")
    private let automationLabel = NSTextField(labelWithString: "自动监控准备中")
    private let timingLabel = NSTextField(labelWithString: "等待采样")
    private let modeControl = NSSegmentedControl(labels: ["自动", "强制开启", "强制关闭"], trackingMode: .selectOne, target: nil, action: nil)
    private let bluetoothSwitch = NSSwitch()
    private let offField = NSTextField()
    private let lowField = NSTextField()
    private let mediumField = NSTextField()
    private let highField = NSTextField()
    private let confirmationDelayField = NSTextField()
    private let shutdownDelayField = NSTextField()
    private let sampleIntervalField = NSTextField()
    private let rulesLabel = NSTextField(wrappingLabelWithString: "")
    private let thresholdStatusLabel = NSTextField(labelWithString: "")
    private let timingSettingsStatusLabel = NSTextField(labelWithString: "")

    init(ble: BLEManager, automation: TemperatureAutomation) {
        self.ble = ble
        self.automation = automation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Magcooler 自动温控")
        title.font = .boldSystemFont(ofSize: 24)

        temperatureLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .bold)
        temperatureLabel.textColor = .systemCyan
        bluetoothLabel.font = .systemFont(ofSize: 14, weight: .medium)
        targetLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        automationLabel.textColor = .secondaryLabelColor
        timingLabel.textColor = .secondaryLabelColor

        modeControl.selectedSegment = automation.mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        let bluetoothTitle = NSTextField(labelWithString: "蓝牙搜索")
        bluetoothSwitch.state = ble.isSearchEnabled ? .on : .off
        bluetoothSwitch.target = self
        bluetoothSwitch.action = #selector(bluetoothSearchChanged)
        bluetoothLabel.stringValue = ble.isSearchEnabled ? "正在初始化蓝牙…" : "蓝牙搜索已关闭"
        let reconnect = button("重新连接", #selector(reconnectTapped))
        let connectionRow = NSStackView(views: [bluetoothTitle, bluetoothSwitch, bluetoothLabel, reconnect])
        connectionRow.orientation = .horizontal
        connectionRow.distribution = .fill
        connectionRow.spacing = 12

        let thresholdsTitle = NSTextField(labelWithString: "自动温度设置")
        thresholdsTitle.font = .boldSystemFont(ofSize: 14)
        configureThresholdField(offField, value: automation.thresholds.off)
        configureThresholdField(lowField, value: automation.thresholds.low)
        configureThresholdField(mediumField, value: automation.thresholds.medium)
        configureThresholdField(highField, value: automation.thresholds.high)
        let thresholdRow = NSStackView(views: [
            NSTextField(labelWithString: "关闭 ≤"), offField,
            NSTextField(labelWithString: "低档 ≥"), lowField,
            NSTextField(labelWithString: "中档 ≥"), mediumField,
            NSTextField(labelWithString: "高档 ≥"), highField,
            button("保存", #selector(saveThresholds))
        ])
        thresholdRow.orientation = .horizontal
        thresholdRow.spacing = 7
        rulesLabel.textColor = .secondaryLabelColor
        rulesLabel.font = .systemFont(ofSize: 12)
        thresholdStatusLabel.textColor = .secondaryLabelColor
        thresholdStatusLabel.font = .systemFont(ofSize: 12)

        let timingsTitle = NSTextField(labelWithString: "自动时间设置")
        timingsTitle.font = .boldSystemFont(ofSize: 14)
        configureTimingField(confirmationDelayField, value: automation.timings.confirmationDelay)
        configureTimingField(shutdownDelayField, value: automation.timings.shutdownDelay)
        configureTimingField(sampleIntervalField, value: automation.timings.sampleInterval)
        let timingSettingsRow = NSStackView(views: [
            NSTextField(labelWithString: "切档确认"), confirmationDelayField,
            NSTextField(labelWithString: "关闭等待"), shutdownDelayField,
            NSTextField(labelWithString: "采样间隔"), sampleIntervalField,
            NSTextField(labelWithString: "秒"),
            button("保存", #selector(saveTimings))
        ])
        timingSettingsRow.orientation = .horizontal
        timingSettingsRow.spacing = 8
        timingSettingsStatusLabel.textColor = .secondaryLabelColor
        timingSettingsStatusLabel.font = .systemFont(ofSize: 12)
        updateRulesLabel(automation.thresholds, timings: automation.timings)

        let lightsTitle = NSTextField(labelWithString: "灯效")
        lightsTitle.font = .boldSystemFont(ofSize: 14)
        let lightRow = NSStackView(views: [
            button("炫彩", #selector(lightColorful)),
            button("彩虹呼吸", #selector(lightRainbow)),
            button("蓝色呼吸", #selector(lightBlue)),
            button("红色常亮", #selector(lightRed)),
            button("关灯", #selector(lightOff)),
            button("默认", #selector(lightDefault))
        ])
        lightRow.orientation = .horizontal
        lightRow.distribution = .fillEqually
        lightRow.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [
            title, temperatureLabel, connectionRow, modeControl,
            targetLabel, automationLabel, timingLabel,
            thresholdsTitle, thresholdRow, thresholdStatusLabel,
            timingsTitle, timingSettingsRow, timingSettingsStatusLabel, rulesLabel,
            separator, lightsTitle, lightRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 620),
            view.heightAnchor.constraint(equalToConstant: 610),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            modeControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            connectionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            thresholdRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            timingSettingsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lightRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        ble.onStatus = { [weak self] text in self?.bluetoothLabel.stringValue = text }
        ble.onTarget = { [weak self] target in self?.targetLabel.stringValue = "目标制冷：\(target.displayName)" }
        automation.onTemperature = { [weak self] temperature in
            self?.temperatureLabel.stringValue = temperature.map { String(format: "%.1f °C", $0) } ?? "读取失败"
        }
        automation.onTiming = { [weak self] text in self?.timingLabel.stringValue = text }
        automation.onAutomationStatus = { [weak self] text in self?.automationLabel.stringValue = text }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func configureThresholdField(_ field: NSTextField, value: Double) {
        field.stringValue = formatThreshold(value)
        field.alignment = .center
        field.target = self
        field.action = #selector(saveThresholds)
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
    }

    private func configureTimingField(_ field: NSTextField, value: TimeInterval) {
        field.stringValue = formatThreshold(value)
        field.alignment = .center
        field.target = self
        field.action = #selector(saveTimings)
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
    }

    private func formatThreshold(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func updateRulesLabel(_ thresholds: TemperatureThresholds, timings: AutomationTimings) {
        rulesLabel.stringValue = "当前规则：≥\(formatThreshold(thresholds.low))°C 低档 · ≥\(formatThreshold(thresholds.medium))°C 中档 · ≥\(formatThreshold(thresholds.high))°C 高档（持续 \(formatThreshold(timings.confirmationDelay)) 秒确认）\n≤\(formatThreshold(thresholds.off))°C 持续 \(formatThreshold(timings.shutdownDelay)) 秒关闭 · 自动控制每 \(formatThreshold(timings.sampleInterval)) 秒采样"
    }

    @objc private func modeChanged() {
        guard let mode = ControlMode(rawValue: modeControl.selectedSegment) else { return }
        automation.setMode(mode)
    }

    @objc private func bluetoothSearchChanged() {
        ble.setSearchEnabled(bluetoothSwitch.state == .on)
    }

    @objc private func saveThresholds() {
        guard
            let off = Double(offField.stringValue),
            let low = Double(lowField.stringValue),
            let medium = Double(mediumField.stringValue),
            let high = Double(highField.stringValue)
        else {
            thresholdStatusLabel.stringValue = "请输入有效数字"
            thresholdStatusLabel.textColor = .systemRed
            NSSound.beep()
            return
        }

        let thresholds = TemperatureThresholds(off: off, low: low, medium: medium, high: high)
        guard automation.setThresholds(thresholds) else {
            thresholdStatusLabel.stringValue = "请保证：关闭 < 低档 < 中档 < 高档（0–120°C）"
            thresholdStatusLabel.textColor = .systemRed
            NSSound.beep()
            return
        }

        thresholdStatusLabel.stringValue = "已保存"
        thresholdStatusLabel.textColor = .systemGreen
        updateRulesLabel(thresholds, timings: automation.timings)
    }

    @objc private func saveTimings() {
        guard
            let confirmationDelay = Double(confirmationDelayField.stringValue),
            let shutdownDelay = Double(shutdownDelayField.stringValue),
            let sampleInterval = Double(sampleIntervalField.stringValue)
        else {
            timingSettingsStatusLabel.stringValue = "请输入有效秒数"
            timingSettingsStatusLabel.textColor = .systemRed
            NSSound.beep()
            return
        }

        let timings = AutomationTimings(
            confirmationDelay: confirmationDelay,
            shutdownDelay: shutdownDelay,
            sampleInterval: sampleInterval
        )
        guard automation.setTimings(timings) else {
            timingSettingsStatusLabel.stringValue = "每项请输入 1–3600 秒"
            timingSettingsStatusLabel.textColor = .systemRed
            NSSound.beep()
            return
        }

        timingSettingsStatusLabel.stringValue = "已保存并立即生效"
        timingSettingsStatusLabel.textColor = .systemGreen
        updateRulesLabel(automation.thresholds, timings: timings)
    }

    @objc private func reconnectTapped() { ble.reconnect() }
    @objc private func lightColorful() { ble.setLight([1, 0, 0, 0]) }
    @objc private func lightRainbow() { ble.setLight([2, 0, 0, 0]) }
    @objc private func lightBlue() { ble.setLight([3, 0, 0, 255]) }
    @objc private func lightRed() { ble.setLight([4, 255, 0, 0]) }
    @objc private func lightOff() { ble.setLight([4, 0, 0, 0]) }
    @objc private func lightDefault() { ble.setLight([5, 0, 0, 0]) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var ble: BLEManager?
    private var automation: TemperatureAutomation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ble = BLEManager()
        let automation = TemperatureAutomation(ble: ble)
        let controller = ControllerViewController(ble: ble, automation: automation)

        let window = NSWindow(contentViewController: controller)
        window.title = "Magcooler 控制器"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.ble = ble
        self.automation = automation
        automation.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { automation?.stop() }
}

@main
enum MagcoolerApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
