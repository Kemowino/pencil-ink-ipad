import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Hardware-level Apple Pencil / 3rd-party stylus recognizer on iPadOS,
/// and seamless Mouse / Trackpad pointer click-and-drag recognizer on Mac Catalyst.
final class PencilDrawingGestureRecognizer: UIGestureRecognizer {
    var onPencilBegan: ((UITouch, UIEvent?) -> Void)?
    var onPencilMoved: ((UITouch, UIEvent?) -> Void)?
    var onPencilEnded: ((UITouch, UIEvent?) -> Void)?
    var onPencilCancelled: ((UITouch, UIEvent?) -> Void)?
    var onPencilReset: (() -> Void)?

    /// Optional gate so tapping inside an active live UITextView or handle doesn't steal input.
    var shouldAcceptTouch: ((UITouch) -> Bool)?

    private var activeTouch: UITouch?

    var pencilOnly: Bool = true {
        didSet {
            configureAllowedTouchTypes()
        }
    }

    private func configureAllowedTouchTypes() {
        #if targetEnvironment(macCatalyst)
        allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        #else
        if pencilOnly {
            allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        } else {
            allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.pencil.rawValue),
                NSNumber(value: UITouch.TouchType.direct.rawValue)
            ]
        }
        #endif
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        configureAllowedTouchTypes()
        requiresExclusiveTouchType = false
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    private func isValidInputTouch(_ touch: UITouch) -> Bool {
        if let gate = shouldAcceptTouch, !gate(touch) {
            return false
        }
        #if targetEnvironment(macCatalyst)
        return touch.type == .indirectPointer || touch.type == .pencil || touch.type == .direct
        #else
        return !pencilOnly || touch.type == .pencil
        #endif
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if activeTouch == nil {
            guard let touch = touches.first(where: { isValidInputTouch($0) }) else {
                state = .failed
                return
            }
            activeTouch = touch
            state = .began
            onPencilBegan?(touch, event)
        } else {
            for t in touches where t !== activeTouch {
                ignore(t, for: event)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let active = activeTouch, touches.contains(active) else { return }
        state = .changed
        onPencilMoved?(active, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let active = activeTouch, touches.contains(active) else { return }
        activeTouch = nil
        onPencilEnded?(active, event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let active = activeTouch, touches.contains(active) else { return }
        activeTouch = nil
        onPencilCancelled?(active, event)
        state = .cancelled
    }

    override func reset() {
        let leaked = activeTouch != nil
        activeTouch = nil
        super.reset()
        if leaked {
            onPencilReset?()
        }
    }
}
