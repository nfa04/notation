import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// The handles of a text selection (the sliders on a phone) for text that is drawn smaller or larger than it is laid out: the page
/// is scaled to the zoom, and the handles follow the text through that scale, so that they would be scaled with it. These keep
/// the size they have on the screen, and still point at the text.
///
/// Where the text is stretched differently along the two axes (each word of a PDF's text layer is fitted to its place), [stretch]
/// says how much, for the handle of that type (null: for both). Then the handles are made right for it, in size and in where
/// they sit.
///
/// Null on a computer, where there are no handles: the usual ones are then right.
TextSelectionControls? selectionControlsAtZoom(double Function() scale, {Offset Function(TextSelectionHandleType? type)? stretch}) {
  Offset of(TextSelectionHandleType? type) {
    final own = stretch?.call(type);
    if (own != null && own.dx.isFinite && own.dy.isFinite && own.dx > 0 && own.dy > 0) return own;
    final s = scale();
    return s.isFinite && s > 0 ? Offset(s, s) : const Offset(1, 1);
  }

  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.fuchsia => _ZoomedHandles(materialTextSelectionHandleControls, of),
    TargetPlatform.iOS => _ZoomedHandles(cupertinoTextSelectionHandleControls, of),
    _ => null,
  };
}

/// The tooltip (copy, paste, ...) over a selection in text that is drawn scaled, in the size it has on the screen.
///
/// The menu is placed by the same link as the handles, so it comes out scaled around the corner of the text: this turns that back.
/// [text] is the context of the text it is for (the state of the field, or of the selection area).
Widget menuAtScreenSize(BuildContext text, Widget menu) {
  final box = text.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return menu;
  // (a unit along the text, as long as it is on the screen; not getMaxScaleOnAxis, which counts the depth, that is never scaled)
  final onScreen = box.getTransformTo(null);
  final scale = (MatrixUtils.transformPoint(onScreen, const Offset(1, 0)) - MatrixUtils.transformPoint(onScreen, Offset.zero)).distance;
  if (scale <= 0 || (scale - 1).abs() < 1e-3) return menu;
  final corner = box.localToGlobal(Offset.zero);
  return Transform(
    transform: Matrix4.identity()
      ..translateByDouble(corner.dx, corner.dy, 0, 1)
      ..scaleByDouble(1 / scale, 1 / scale, 1, 1)
      ..translateByDouble(-corner.dx, -corner.dy, 0, 1),
    child: menu,
  );
}

class _ZoomedHandles extends TextSelectionControls with TextSelectionHandleControls {
  _ZoomedHandles(this.base, this.scale);

  final TextSelectionControls base;

  /// How much the text is made larger on the screen, along each axis, at the handle of this type.
  final Offset Function(TextSelectionHandleType? type) scale;

  // (laid out at 1/scale of the size, which the scale then makes the size it has)
  @override
  Size getHandleSize(double textLineHeight) {
    final size = base.getHandleSize(textLineHeight), s = scale(null);
    return Size(size.width / s.dx, size.height / s.dy);
  }

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) {
    final anchor = base.getHandleAnchor(type, textLineHeight), s = scale(type);
    return Offset(anchor.dx / s.dx, anchor.dy / s.dy);
  }

  @override
  Widget buildHandle(BuildContext context, TextSelectionHandleType type, double textLineHeight, [VoidCallback? onTap]) {
    final size = base.getHandleSize(textLineHeight), s = scale(null);
    return _OnScreenDrag(
      child: SizedBox(
        width: size.width / s.dx,
        height: size.height / s.dy,
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox.fromSize(size: size, child: base.buildHandle(context, type, textLineHeight, onTap)),
        ),
      ),
    );
  }
}

/// A handle sits in the text, so what it is dragged through is scaled with the text: a finger that moves 10 pixels moves the
/// handle's drag by 10 pixels divided by the zoom (and by the stretch of the word), and the selection lags behind the finger
/// (or runs ahead of it). This hands the drag on in pixels of the screen.
///
/// It reaches into the handle's drag recogniser (the selection's own, a few levels above) and wraps its update. That is done
/// during layout, where the framework allows a recogniser to be replaced, and again whenever the selection has rebuilt the
/// handle, which sets the recogniser's callbacks anew.
class _OnScreenDrag extends StatelessWidget {
  const _OnScreenDrag({required this.child});

  final Widget child;

  static final _wrapped = Expando<bool>('on screen drag');

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (inner, _) {
          final detector = inner.findAncestorStateOfType<RawGestureDetectorState>();
          if (detector != null) {
            detector.replaceGestureRecognizers(<Type, GestureRecognizerFactory>{
              PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                PanGestureRecognizer.new,
                (pan) {
                  final update = pan.onUpdate;
                  if (update == null || _wrapped[update] == true) return;
                  void onScreen(DragUpdateDetails d) {
                    final box = inner.mounted ? inner.findRenderObject() : null;
                    var delta = d.delta;
                    if (box is RenderBox && box.attached && box.hasSize) {
                      final m = box.getTransformTo(null); // (with the layer link's transform: that is where the scale is)
                      delta = MatrixUtils.transformPoint(m, d.delta) - MatrixUtils.transformPoint(m, Offset.zero);
                    }
                    update(DragUpdateDetails(
                      sourceTimeStamp: d.sourceTimeStamp,
                      delta: delta,
                      globalPosition: d.globalPosition,
                      localPosition: d.localPosition,
                      kind: d.kind,
                    ));
                  }

                  _wrapped[onScreen] = true;
                  pan.onUpdate = onScreen;
                },
              ),
            });
          }
          return child;
        },
      );
}
