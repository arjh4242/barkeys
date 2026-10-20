import Cocoa
import IOBluetooth
import UserNotifications

// Battery level for a Bluetooth device is not part of any public, documented
// macOS API. This uses the long-standing community technique of reading the
// "batteryPercent" key via KVC on IOBluetoothDevice, which only Apple-made
// accessories (AirPods, Magic Mouse/Keyboard/Trackpad) populate. Third-party
// devices typically do not respond to the selector, so `battery` stays nil.
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

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in paired where device.isConnected() {
                let address = device.addressString ?? UUID().uuidString
                let name = device.name ?? L.text(da: "Ukendt enhed", en: "Unknown device")

                var battery: Int? = nil
                if device.responds(to: batterySelector),
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
