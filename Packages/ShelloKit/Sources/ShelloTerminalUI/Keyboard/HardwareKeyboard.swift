import Foundation
import GameController

/// Whether a hardware keyboard is attached to the device, and when that changes (README section 6):
/// while one is, the terminal shows no Shello keyboard. `GameControllerKeyboardMonitor` follows the
/// device's keyboards; `HardwareKeyboardStandIn` is a keyboard that tests attach and detach
/// themselves, which the UI tests use in place of the Simulator's own.
public protocol HardwareKeyboardMonitor: AnyObject {
    /// Whether a hardware keyboard is attached.
    var isAttached: Bool { get }
    /// Calls `changed` with `isAttached` each time it changes, for as long as the observation it
    /// returns lives.
    func observe(_ changed: @escaping (_ isAttached: Bool) -> Void) -> HardwareKeyboardObservation
}

/// An observation of a `HardwareKeyboardMonitor`, which ends when it is released.
public final class HardwareKeyboardObservation {
    private let end: () -> Void

    public init(ending end: @escaping () -> Void) {
        self.end = end
    }

    isolated deinit {
        end()
    }
}

/// The observers of a monitor, which it tells each change.
final class HardwareKeyboardObservers {
    private var observers: [UUID: (Bool) -> Void] = [:]

    func add(_ changed: @escaping (Bool) -> Void) -> HardwareKeyboardObservation {
        let id = UUID()
        observers[id] = changed
        return HardwareKeyboardObservation { [weak self] in
            self?.observers[id] = nil
        }
    }

    func tell(_ isAttached: Bool) {
        for changed in observers.values {
            changed(isAttached)
        }
    }
}

/// The device's hardware keyboards, as GameController reports them (STACK section 7.5). It merges
/// every keyboard into one, `GCKeyboard.coalesced`, so it says once that one connected, and once
/// that the last one disconnected: a keyboard is attached in between.
public final class GameControllerKeyboardMonitor: HardwareKeyboardMonitor {
    public private(set) var isAttached: Bool

    private let observers = HardwareKeyboardObservers()
    private let center: NotificationCenter
    private var notificationObservers: [any NSObjectProtocol] = []

    public convenience init() {
        self.init(center: .default, isAttached: GCKeyboard.coalesced != nil)
    }

    /// Follows the connections and disconnections that `center` reports, from `isAttached`.
    init(center: NotificationCenter, isAttached: Bool) {
        self.center = center
        self.isAttached = isAttached
        let changes: [(Notification.Name, Bool)] = [(.GCKeyboardDidConnect, true), (.GCKeyboardDidDisconnect, false)]
        for (name, attached) in changes {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAttached(attached) }
            }
            notificationObservers.append(observer)
        }
    }

    isolated deinit {
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
    }

    public func observe(_ changed: @escaping (Bool) -> Void) -> HardwareKeyboardObservation {
        observers.add(changed)
    }

    private func setAttached(_ attached: Bool) {
        guard attached != isAttached else { return }
        isAttached = attached
        observers.tell(attached)
    }
}

/// A hardware keyboard that tests attach and detach, in place of the device's.
public final class HardwareKeyboardStandIn: HardwareKeyboardMonitor {
    public var isAttached: Bool {
        didSet {
            if isAttached != oldValue {
                observers.tell(isAttached)
            }
        }
    }

    private let observers = HardwareKeyboardObservers()

    public init(isAttached: Bool = false) {
        self.isAttached = isAttached
    }

    public func observe(_ changed: @escaping (Bool) -> Void) -> HardwareKeyboardObservation {
        observers.add(changed)
    }
}
