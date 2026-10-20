import Cocoa
import IOBluetooth
import IOKit.hid
import UserNotifications

// Battery level for a Bluetooth device is not part of any public, documented
// macOS API. Two community techniques are combined here:
// 1. IOHIDManager: devices that implement the standard Bluetooth HID Battery
//    Service (many "Made for Mac" mice/keyboards/trackpads, not just Apple's)
//    expose a "BatteryPercent" property on their IOHIDDevice. This is the
//    more broadly applicable source and is tried first.
// 2. IOBluetoothDevice's private "batteryPercent" KVC key, which Apple's own
//    accessories (AirPods, Magic Mouse/Keyboard/Trackpad) populate even when
//    they don't surface it through IOHIDManager.
// Devices using audio profiles (A2DP/HFP) such as headphones, earbuds and
// speakers don't expose battery through either path, so `battery` stays nil
// for those.
struct BluetoothDeviceInfo {
    let address: String
    let name: String
    let battery: Int?
}

final class BluetoothBatteryMonitor {
    private(set) var devices: [BluetoothDeviceInfo] = []
    private var notifiedAddresses: Set<String> = []
    private var timer: Timer?

    var onUpdate: (() -> Void)?

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        var result: [BluetoothDeviceInfo] = []
        let batterySelector = NSSelectorFromString("batteryPercent")
        let hidBatteries = hidBluetoothBatteryLevels()

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in paired where device.isConnected() {
                let address = device.addressString ?? UUID().uuidString
                let name = device.name ?? L.text(da: "Ukendt enhed", en: "Unknown device")

                var battery: Int? = hidBatteries[name]
                if battery == nil,
                   device.responds(to: batterySelector),
                   let value = device.value(forKey: "batteryPercent") as? Int,
                   value >= 0, value <= 100 {
                    battery = value
                }

                result.append(BluetoothDeviceInfo(address: address, name: name, battery: battery))
                checkAlarm(address: address, name: name, battery: battery)
            }
        }

        devices = result.sorted { $0.name < $1.name }
        onUpdate?()
    }

    private func hidBluetoothBatteryLevels() -> [String: Int] {
        var result: [String: Int] = [:]

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return result
        }

        for device in deviceSet {
            guard let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                  transport.localizedCaseInsensitiveContains("bluetooth") else { continue }
            guard let percent = IOHIDDeviceGetProperty(device, "BatteryPercent" as CFString) as? Int,
                  percent >= 0, percent <= 100 else { continue }
            guard let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String else { continue }
            result[name] = percent
        }

        return result
    }

    private func checkAlarm(address: String, name: String, battery: Int?) {
        guard isAlarmEnabled(), let battery else { return }
        let threshold = alarmThreshold()

        if battery <= threshold {
            if !notifiedAddresses.contains(address) {
                notifiedAddresses.insert(address)
                sendLowBatteryNotification(name: name, battery: battery)
            }
        } else if battery > threshold + 5 {
            // Hysteresis so the alarm can fire again after a recharge.
            notifiedAddresses.remove(address)
        }
    }

    private func sendLowBatteryNotification(name: String, battery: Int) {
        let content = UNMutableNotificationContent()
        content.title = L.text(da: "Lavt batteri", en: "Low battery")
        content.body = L.text(
            da: "\(name) har \(battery)% batteri tilbage.",
            en: "\(name) has \(battery)% battery remaining."
        )
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func isAlarmEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "bluetoothAlarmEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "bluetoothAlarmEnabled")
    }

    func setAlarmEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "bluetoothAlarmEnabled")
    }

    func alarmThreshold() -> Int {
        UserDefaults.standard.object(forKey: "bluetoothAlarmThreshold") as? Int ?? 20
    }

    func setAlarmThreshold(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "bluetoothAlarmThreshold")
        notifiedAddresses.removeAll()
    }
}
