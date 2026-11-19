import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Hardware-level Apple Pencil / 3rd-party stylus recognizer.
/// Sets `allowedTouchTypes = [.pencil]` and `requiresExclusiveTouchType = false`
/// so a resting palm or forearm NEVER blocks the stylus, and fingers NEVER trigger drawing.
final class PencilDrawingGestureRecognizer: UIGestureRecognizer {
    var onPencilBegan: ((UITouch, UIEvent?) -> Void)?
    var onPencilMoved: ((UITouch, UIEvent?) -> Void)?
    var onPencilEnded: ((UITouch, UIEvent?) -> Void)?
    var onPencilCancelled: ((UITouch, UIEvent?) -> Void)?

    private var activeTouch: UITouch?

    var pencilOnly: Bool = true {
        didSet {
            if pencilOnly {
                allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            } else {
                allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.pencil.rawValue),
                    NSNumber(value: UITouch.TouchType.direct.rawValue)
                ]
            }
        }
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        requiresExclusiveTouchType = false
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let valid = touches.filter { !pencilOnly || $0.type == .pencil }
        guard let touch = activeTouch ?? valid.first else {
            return
        }
        // Ignore extra non-active touches while a stroke is already in progress
        if activeTouch != nil && touch !== activeTouch {
            for t in touches where t !== activeTouch { ignore(t, for: event) }
            return
        }
        activeTouch = touch
        state = .began
        onPencilBegan?(touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let active = activeTouch, touches.contains(active) else { return }
        state = .changed
        onPencilMoved?(active, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let active = activeTouch, touches.contains(active) else { return }
        onPencilEnded?(active, event)
        activeTouch = nil
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let active = activeTouch, touches.contains(active) else { return }
        onPencilCancelled?(active, event)
        activeTouch = nil
        state = .cancelled
    }

    override func reset() {
        super.reset()
        activeTouch = nil
    }
}
