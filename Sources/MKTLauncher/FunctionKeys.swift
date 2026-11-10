import Foundation
import IOKit
import IOKit.hid

/// Makes F1–F12 act as standard function keys (no fn needed) while MKT Launcher is the
/// active app, and restores the user's system setting when they switch away or quit.
/// Same mechanism utilities like Fluor use: the HIDFKeyMode parameter of IOHIDSystem.
enum FunctionKeys {
    static let enabledKey = "standardFunctionKeys"
    private static let savedModeKey = "savedHIDFKeyMode"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func appDidBecomeActive() {
        guard enabled, let current = mode() else { return }
        // Keep the value saved by a previous run if we never got to restore it (crash).
        if UserDefaults.standard.object(forKey: savedModeKey) == nil {
            UserDefaults.standard.set(current, forKey: savedModeKey)
        }
        if current != 1 { setMode(1) }
    }

    static func appDidResignActive() {
        guard let saved = UserDefaults.standard.object(forKey: savedModeKey) as? Int else { return }
        setMode(saved)
        UserDefaults.standard.removeObject(forKey: savedModeKey)
    }

    // MARK: IOKit

    private static func withHIDSystem<T>(_ body: (io_connect_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return nil
        }
        defer { IOServiceClose(connect) }
        return body(connect)
    }

    /// 0 = media keys by default (fn for F-keys), 1 = standard F-keys.
    static func mode() -> Int? {
        withHIDSystem { c in
            var value: UInt32 = 0
            var size: IOByteCount = 0
            let kr = IOHIDGetParameter(c, kIOHIDFKeyModeKey as CFString,
                                       IOByteCount(MemoryLayout<UInt32>.size), &value, &size)
            return kr == KERN_SUCCESS ? Int(value) : nil
        }
    }

    @discardableResult
    static func setMode(_ mode: Int) -> Bool {
        withHIDSystem { c in
            var value = UInt32(mode)
            return IOHIDSetParameter(c, kIOHIDFKeyModeKey as CFString, &value,
                                     IOByteCount(MemoryLayout<UInt32>.size)) == KERN_SUCCESS
        } ?? false
    }
}
