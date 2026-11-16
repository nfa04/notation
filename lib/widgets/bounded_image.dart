import 'dart:async' show scheduleMicrotask;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// [provider] decoded no larger than it is shown: [width] by [height] pixels of the screen, covered ([cover]: the picture fills the box
/// and what sticks out is cut off, as [BoxFit.cover]) or fitted into it. Never larger than the picture is.
///
/// A photo from a camera is 12 megapixels, about 48 MB once decoded, and a picture decoded at full size stays that big in the cache of
/// pictures however small it is shown. [ResizeImage] cannot be told to cover a box (its sizes fit into one), and a width alone blurs a
/// wide picture that covers a tall box; this works the size out from the picture's own when it is read, before it is decoded.
@immutable
class BoundedImage extends ImageProvider<BoundedImageKey> {
  final ImageProvider<Object> provider;
  final int width, height;
  final bool cover;

  const BoundedImage(this.provider, {required this.width, required this.height, this.cover = false});

  /// The size [intrinsicWidth] by [intrinsicHeight] is decoded at for a box of [width] by [height].
  static ui.TargetImageSize target(int intrinsicWidth, int intrinsicHeight, int width, int height, {required bool cover}) {
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) return const ui.TargetImageSize();
    final sx = width / intrinsicWidth, sy = height / intrinsicHeight;
    final scale = cover ? math.max(sx, sy) : math.min(sx, sy);
    if (scale >= 1) return const ui.TargetImageSize(); // (smaller than the box already: as it is)
    return ui.TargetImageSize(width: math.max(1, (intrinsicWidth * scale).ceil()), height: math.max(1, (intrinsicHeight * scale).ceil()));
  }

  @override
  Future<BoundedImageKey> obtainKey(ImageConfiguration configuration) {
    // (synchronous when the inner provider's key is, as for a file: the picture shows in the first frame when it is in the cache)
    SynchronousFuture<BoundedImageKey>? now;
    final later = provider.obtainKey(configuration).then((key) {
      final k = BoundedImageKey._(key, width, height, cover);
      now = SynchronousFuture(k);
      return k;
    });
    return now ?? later;
  }

  @override
  ImageStreamCompleter loadImage(BoundedImageKey key, ImageDecoderCallback decode) {
    Future<ui.Codec> bounded(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) =>
        decode(buffer, getTargetSize: (w, h) => target(w, h, width, height, cover: cover));
    final completer = provider.loadImage(key._inner, bounded);
    // (a picture that failed is not kept: it is tried again the next time, as ResizeImage does)
    completer.addEphemeralErrorListener((_, _) => scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key)));
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is BoundedImage && other.provider == provider && other.width == width && other.height == height && other.cover == cover;

  @override
  int get hashCode => Object.hash(provider, width, height, cover);
}

@immutable
class BoundedImageKey {
  final Object _inner;
  final int _width, _height;
  final bool _cover;

  const BoundedImageKey._(this._inner, this._width, this._height, this._cover);

  @override
  bool operator ==(Object other) =>
      other is BoundedImageKey && other._inner == _inner && other._width == _width && other._height == _height && other._cover == _cover;

  @override
  int get hashCode => Object.hash(_inner, _width, _height, _cover);
}

/// [n] screen pixels, rounded up to a step, so that a box that changes size a little (a window pulled wider, a card that grows by a
/// pixel) does not decode the picture again. The steps grow with the size: an eighth of the next power of two, at least 64.
int roundedPixels(double n) {
  if (!n.isFinite || n <= 64) return 64;
  final step = math.max(64, (1 << (n.ceil().bitLength - 1)) ~/ 8);
  return (n / step).ceil() * step;
}

/// [file] shown in the box it is laid out in, decoded no larger than that box on this screen (see [BoundedImage]). With no bounded
/// size to go by (an unbounded list), [width] and [height] are used; with neither, the picture is decoded as it is.
class BoundedFileImage extends StatelessWidget {
  final File file;
  final BoxFit fit;
  final Alignment alignment;
  final double? width, height;
  final bool gaplessPlayback;
  final ImageErrorWidgetBuilder? errorBuilder;

  const BoundedFileImage(this.file, {super.key, this.fit = BoxFit.cover, this.alignment = Alignment.center, this.width, this.height, this.gaplessPlayback = false, this.errorBuilder});

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    Widget image(double? w, double? h) => Image(
          image: boundedFile(file, w, h, ratio, cover: fit == BoxFit.cover),
          width: width,
          height: height,
          fit: fit,
          alignment: alignment,
          gaplessPlayback: gaplessPlayback,
          errorBuilder: errorBuilder,
        );
    // (a size given in full needs no layout to be known: and a LayoutBuilder cannot be measured, as a picture inside text is)
    if (width != null && height != null) return image(width, height);
    return LayoutBuilder(builder: (context, box) => image(box.hasBoundedWidth ? box.maxWidth : width, box.hasBoundedHeight ? box.maxHeight : height));
  }
}

/// The picture in [file] for a box of [w] by [h] logical pixels on a screen of [ratio] (see [BoundedImage]); a side that is null does not
/// bound it, and with neither it is decoded as it is.
ImageProvider boundedFile(File file, double? w, double? h, double ratio, {bool cover = false}) {
  if (w == null && h == null) return FileImage(file);
  return BoundedImage(
    FileImage(file),
    width: w == null ? 1 << 20 : roundedPixels(w * ratio),
    height: h == null ? 1 << 20 : roundedPixels(h * ratio),
    cover: cover && w != null && h != null,
  );
}
