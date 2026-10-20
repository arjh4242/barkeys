import Cocoa
import IOBluetooth
import IOKit.hid
import UserNotifications

// Battery level for a Bluetooth device is not part of any public, documented
// macOS API. Three sources are tried, in order of how closely they match
// what System Settings itself shows:
// 1. BatteryCenter.framework (private): the same backing store System
//    Settings' Bluetooth pane and Control Center read from for ANY
//    accessory (Apple or third-party) that reports battery, regardless of
//    which underlying profile it uses.
// 2. IOHIDManager: devices implementing the standard Bluetooth HID Battery
//    Service expose a "BatteryPercent" property on their IOHIDDevice.
// 3. IOBluetoothDevice's private "batteryPercent" KVC key, which mainly
//    works for Apple's own accessories.
// Devices on audio profiles (A2DP/HFP) such as headphones, earbuds and
// speakers generally don't expose battery through any of these, so
// `battery` stays nil for those.
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
        let batteryCenter = batteryCenterLevels()
        let hidBatteries = hidBluetoothBatteryLevels()

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in paired where device.isConnected() {
                let address = device.addressString ?? UUID().uuidString
                let name = device.name ?? L.text(da: "Ukendt enhed", en: "Unknown device")

                var battery: Int? = matchBattery(name: name, in: batteryCenter)
                    ?? matchBattery(name: name, in: hidBatteries)
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

    private func matchBattery(name: String, in dict: [String: Int]) -> Int? {
        if let exact = dict[name] { return exact }
        let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()
        for (key, value) in dict {
            if key.trimmingCharacters(in: .whitespaces).lowercased() == normalized {
                return value
            }
        }
        return nil
    }

    // Loads the private BatteryCenter framework used internally by System
    // Settings and Control Center, and reads its device list via KVC. This
    // can break on future macOS versions since it's not a public API; if
    // loading or any step fails, this simply returns an empty dictionary
    // and the other two sources are used instead.
    private func batteryCenterLevels() -> [String: Int] {
        var result: [String: Int] = [:]

        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/BatteryCenter.framework"),
              bundle.load(),
              let cls = NSClassFromString("BCBatteryDeviceController") else {
            return result
        }

        let clsObject = cls as AnyObject
        let sharedSelector = NSSelectorFromString("sharedInstance")
        guard clsObject.responds(to: sharedSelector),
              let controller = clsObject.perform(sharedSelector)?.takeUnretainedValue() as? NSObject else {
            return result
        }

        guard let bcDevices = controller.value(forKey: "devices") as? [NSObject] else {
            return result
        }

        for device in bcDevices {
            guard let name = device.value(forKey: "name") as? String,
                  let percent = device.value(forKey: "current") as? Int,
                  percent >= 0, percent <= 100 else { continue }
            result[name] = percent
        }

        return result
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
