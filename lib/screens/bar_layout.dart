import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Tells [onHeight] how high its child turned out to be, and [onWidth] how wide it is in one line, so that a bar whose tools wrap
/// onto more rows can be given the room, and only when they do not fit in one.
class HeightReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onHeight;
  final ValueChanged<double>? onWidth;
  const HeightReporter({super.key, required this.onHeight, this.onWidth, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHeightReporter(onHeight, onWidth);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderHeightReporter)
      ..onHeight = onHeight
      ..onWidth = onWidth;
  }
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight, this.onWidth);
  ValueChanged<double> onHeight;
  ValueChanged<double>? onWidth;
  double? _lastHeight, _lastWidth;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // in one line if it fits, else at the width there is (so that it wraps only then)
    child.layout(constraints.copyWith(maxWidth: double.infinity), parentUsesSize: true);
    final natural = child.size.width;
    if (natural > constraints.maxWidth) child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
    final h = size.height;
    if (h != _lastHeight) {
      _lastHeight = h;
      WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h));
    }
    final report = onWidth;
    if (report != null && natural != _lastWidth) {
      _lastWidth = natural;
      WidgetsBinding.instance.addPostFrameCallback((_) => report(natural));
    }
  }
}
