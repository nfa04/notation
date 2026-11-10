import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A pan that is recognised after a few pixels. The page list scrolls after 18,
/// so a vertical drag on a text box or a picture would scroll the list instead
/// of moving the thing, if it had to wait for the usual pan distance (36).
class _EarlyPanRecognizer extends PanGestureRecognizer {
  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      globalDistanceMoved.abs() > 6.0;
}

/// Tap and drag on something that can be moved, winning over the scrolling
/// list behind it.
class ElementDragDetector extends StatelessWidget {
  final VoidCallback? onTap;

  /// Like [onTap], with where in this widget the tap was.
  final void Function(TapUpDetails details)? onTapUp;

  /// The drag was taken up, at this global position.
  final void Function(Offset globalPosition)? onDragStart;

  /// Only for drags that are not about moving ([onDragStart] covers that).
  final void Function(Offset delta)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final Widget? child;

  const ElementDragDetector({
    super.key,
    this.onTap,
    this.onTapUp,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        if (onTap != null || onTapUp != null)
          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            TapGestureRecognizer.new,
            (t) => t
              ..onTap = onTap
              ..onTapUp = onTapUp,
          ),
        _EarlyPanRecognizer: GestureRecognizerFactoryWithHandlers<_EarlyPanRecognizer>(
          _EarlyPanRecognizer.new,
          (pan) {
            pan.onStart = (d) => onDragStart?.call(d.globalPosition);
            pan.onUpdate = (d) => onDragUpdate?.call(d.delta);
            pan.onEnd = (_) => onDragEnd?.call();
          },
        ),
      },
      child: child,
    );
  }
}
