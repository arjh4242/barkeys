import Cocoa
import ApplicationServices

private let kVK_ANSI_Z: CGKeyCode = 0x06
private let kVK_ANSI_X: CGKeyCode = 0x07
private let kVK_ANSI_C: CGKeyCode = 0x08
private let kVK_ANSI_V: CGKeyCode = 0x09

private func postCommandKey(_ keyCode: CGKeyCode, flags: CGEventFlags = .maskCommand) {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private enum AppLanguage: String {
    case danish = "da"
    case english = "en"
}

private enum L {
    static var lang: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: "language"), let l = AppLanguage(rawValue: raw) {
            return l
        }
        return .danish
    }

    static func text(da: String, en: String) -> String {
        lang == .danish ? da : en
    }
}

// CaseIterable order (declaration order) is used as the on-screen order, left to right.
private enum Shortcut: String, CaseIterable {
    case undo = "showUndo"
    case redo = "showRedo"
    case cut = "showCut"
    case copy = "showCopy"
    case paste = "showPaste"

    var symbol: String {
        switch self {
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .cut: return "scissors"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .undo, .redo: return kVK_ANSI_Z
        case .cut: return kVK_ANSI_X
        case .copy: return kVK_ANSI_C
        case .paste: return kVK_ANSI_V
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .redo: return [.maskCommand, .maskShift]
        default: return .maskCommand
        }
    }

    func menuTitle() -> String {
        switch self {
        case .undo: return L.text(da: "Fortryd (⌘Z)", en: "Undo (⌘Z)")
        case .redo: return L.text(da: "Gentag (⇧⌘Z)", en: "Redo (⇧⌘Z)")
        case .cut: return L.text(da: "Klip (⌘X)", en: "Cut (⌘X)")
        case .copy: return L.text(da: "Kopier (⌘C)", en: "Copy (⌘C)")
        case .paste: return L.text(da: "Indsæt (⌘V)", en: "Paste (⌘V)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItems: [Shortcut: NSStatusItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        checkAccessibilityPermission()

        for shortcut in Shortcut.allCases.reversed() {
            statusItems[shortcut] = makeShortcutItem(shortcut)
        }

        applyVisibility()
    }

    private func checkAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func makeShortcutItem(_ shortcut: Shortcut) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: shortcut.symbol, accessibilityDescription: shortcut.menuTitle())
            button.image?.isTemplate = true
            button.toolTip = shortcut.menuTitle()
            button.target = self
            button.action = #selector(shortcutClicked(_:))
            button.tag = Shortcut.allCases.firstIndex(of: shortcut) ?? 0
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        return item
    }

    @objc private func shortcutClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(buildMenu(), with: event, for: sender)
        } else {
            let shortcut = Shortcut.allCases[sender.tag]
            postCommandKey(shortcut.keyCode, flags: shortcut.flags)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        for shortcut in Shortcut.allCases {
            let item = NSMenuItem(title: shortcut.menuTitle(), action: #selector(toggleShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.state = isEnabled(shortcut) ? .on : .off
            item.representedObject = shortcut
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let languageItem = NSMenuItem(title: L.text(da: "Sprog", en: "Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let danish = NSMenuItem(title: "Dansk", action: #selector(setDanish), keyEquivalent: "")
        danish.target = self
        danish.state = L.lang == .danish ? .on : .off
        let english = NSMenuItem(title: "English", action: #selector(setEnglish), keyEquivalent: "")
        english.target = self
        english.state = L.lang == .english ? .on : .off
        languageMenu.addItem(danish)
        languageMenu.addItem(english)
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L.text(da: "Afslut BarKeys", en: "Quit BarKeys"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleShortcut(_ sender: NSMenuItem) {
        guard let shortcut = sender.representedObject as? Shortcut else { return }
        let turningOff = sender.state == .on
        if turningOff {
            // Keep at least one icon visible so the settings menu stays reachable.
            let visibleCount = Shortcut.allCases.filter { isEnabled($0) }.count
            if visibleCount <= 1 { return }
        }
        let newValue = !turningOff
        UserDefaults.standard.set(newValue, forKey: shortcut.rawValue)
        statusItems[shortcut]?.isVisible = newValue
    }

    @objc private func setDanish() {
        UserDefaults.standard.set(AppLanguage.danish.rawValue, forKey: "language")
        updateTooltips()
    }

    @objc private func setEnglish() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: "language")
        updateTooltips()
    }

    private func updateTooltips() {
        for shortcut in Shortcut.allCases {
            statusItems[shortcut]?.button?.toolTip = shortcut.menuTitle()
        }
    }

    private func isEnabled(_ shortcut: Shortcut) -> Bool {
        if UserDefaults.standard.object(forKey: shortcut.rawValue) == nil { return true }
        return UserDefaults.standard.bool(forKey: shortcut.rawValue)
    }

    private func applyVisibility() {
        for shortcut in Shortcut.allCases {
            statusItems[shortcut]?.isVisible = isEnabled(shortcut)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
