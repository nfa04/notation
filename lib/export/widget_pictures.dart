import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A widget drawn to a picture: [image] is [pixelRatio] times as many pixels as [size] (in the units of the page).
class WidgetPicture {
  final ui.Image image;
  final Size size;

  WidgetPicture(this.image, this.size);

  void dispose() => image.dispose();
}

/// Draws each of [widgets] to a picture, as it looks on a light screen (the paper is white), at [pixelRatio] pixels to a unit - or
/// fewer where it would be more than [maxSide] pixels on a side. A widget that has no size has no picture (null). Needs the app on
/// screen: the widgets are laid out in an overlay, out of sight. The caller disposes the pictures.
Future<List<WidgetPicture?>> pictureWidgets(
  BuildContext context,
  List<Widget> widgets, {
  required double pixelRatio,
  double maxSide = 8192,
}) async {
  if (widgets.isEmpty) return const [];
  final keys = [for (var i = 0; i < widgets.length; i++) GlobalKey()];
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -100000, // far off screen; it is still painted into its own layer
      top: 0,
      // (as tall as the widgets are, not as the screen)
      child: UnconstrainedBox(
        alignment: Alignment.topLeft,
        clipBehavior: Clip.none,
        child: Theme(
          data: ThemeData.light(),
          child: Material(
            type: MaterialType.transparency,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < widgets.length; i++) RepaintBoundary(key: keys[i], child: widgets[i]),
            ]),
          ),
        ),
      ),
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  try {
    await WidgetsBinding.instance.endOfFrame;
    final pictures = <WidgetPicture?>[];
    for (final key in keys) {
      final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || !boundary.hasSize || boundary.size.isEmpty) {
        pictures.add(null);
        continue;
      }
      final ratio = pixelRatio.clamp(0.1, maxSide / boundary.size.longestSide).toDouble();
      pictures.add(WidgetPicture(await boundary.toImage(pixelRatio: ratio), boundary.size));
    }
    return pictures;
  } finally {
    entry.remove();
  }
}
