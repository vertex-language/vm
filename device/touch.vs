package device

/// A touchscreen with keys, as an Android guest reads it (goldfish-events
/// on the emulator's older kernels, virtio-input from Android 10): what a
/// window sends touches and key presses to.
public protocol TouchScreen: AnyObject {
    /// A key (an evdev KEY_ code) going down or up.
    func Key(_ code: uint16, pressed: bool)
    /// A finger at (x, y) in screen pixels: down, moving, or lifted.
    func Touch(x: int, y: int, down: bool)
    /// Whether a finger is down: a pointer moving without one is not a touch.
    var Touching: bool { get }
}
