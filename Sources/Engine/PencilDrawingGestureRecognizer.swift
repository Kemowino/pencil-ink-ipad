import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Hardware-level Apple Pencil / 3rd-party stylus recognizer.
/// Follows Apple's "Leveraging Touch Input for Drawing Apps" pattern:
/// - `allowedTouchTypes = [.pencil]` so fingers NEVER trigger drawing.
/// - `requiresExclusiveTouchType = false` so a resting palm NEVER blocks the stylus.
/// - `cancelsTouchesInView = false` so it NEVER interferes with UIScrollView's finger pan/pinch.
final class PencilDrawingGestureRecognizer: UIGestureRecognizer {
    var onPencilBegan: ((UITouch, UIEvent?) -> Void)?
    var onPencilMoved: ((UITouch, UIEvent?) -> Void)?
    var onPencilEnded: ((UITouch, UIEvent?) -> Void)?
    var onPencilCancelled: ((UITouch, UIEvent?) -> Void)?
    var onPencilReset: (() -> Void)?

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
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let valid = touches.filter { !pencilOnly || $0.type == .pencil }
        if activeTouch == nil {
            guard let touch = valid.first else {
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
