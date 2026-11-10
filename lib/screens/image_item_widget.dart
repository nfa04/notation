import 'dart:io';
import '../l10n/language.dart';

import 'package:flutter/material.dart';

import '../models/image_item.dart';
import 'element_drag_detector.dart';

/// A picture on a page. While [interactive] a tap selects it; the selected
/// picture can be dragged, resized by its corner and deleted.
class ImageItemWidget extends StatelessWidget {
  final ImageItem item;
  final bool interactive;

  /// False for the transparent control layer that sits above the page's other
  /// layers while the picture itself is drawn below them.
  final bool showPicture;
  final bool selected;
  final VoidCallback onSelect;

  /// A tap on the picture, when that is not the same as picking it (null: it is).
  final VoidCallback? onTap;

  /// A drag of the picture begins (global position); the editor follows the
  /// pointer from there, so that the picture can go on to another page.
  final void Function(Offset globalPosition) onMoveStart;
  final void Function(Offset delta) onResize;
  final VoidCallback onDelete;

  /// Makes a copy of the picture; null hides the button.
  final VoidCallback? onDuplicate;

  /// Opens the picture to be edited (crop, colours, background); null hides the button.
  final VoidCallback? onEdit;

  /// Makes the picture a reference to trace (faded, locked, under everything else); null hides the button.
  final VoidCallback? onReference;

  /// Takes the colours of the picture for the pen; null hides the button.
  final VoidCallback? onPalette;
  final VoidCallback onChangeEnd;

  /// How much of the picture shows (its layer's opacity).
  final double opacity;

  static const double minWidth = 40;

  const ImageItemWidget({
    super.key,
    required this.item,
    required this.interactive,
    this.showPicture = true,
    required this.selected,
    required this.onSelect,
    this.onTap,
    required this.onMoveStart,
    required this.onResize,
    required this.onDelete,
    this.onDuplicate,
    this.onEdit,
    this.onReference,
    this.onPalette,
    this.opacity = 1,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = Image.file(
      File(item.path),
      width: item.size.width,
      height: item.size.height,
      fit: BoxFit.fill,
      errorBuilder: (_, _, _) => Container(
        width: item.size.width,
        height: item.size.height,
        color: Colors.black12,
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
    final picture = opacity < 1 ? Opacity(opacity: opacity, child: image) : image;
    // room around the picture for the handle and the delete button: taps are
    // only delivered inside the bounds of a widget
    final w = item.size.width, h = item.size.height;
    return Positioned(
      left: item.position.dx - _pad,
      top: item.position.dy - _padTop,
      width: w + 2 * _pad,
      height: h + _padTop + _pad,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: _pad,
          top: _padTop,
          width: w,
          height: h,
          child: interactive
              ? ElementDragDetector(
                  onTap: onTap ?? onSelect,
                  onDragStart: (global) {
                    onSelect();
                    onMoveStart(global);
                  },
                  child: Container(
                    decoration: selected ? BoxDecoration(border: Border.all(color: scheme.primary, width: 2)) : null,
                    child: showPicture ? picture : null,
                  ),
                )
              : IgnorePointer(child: picture),
        ),
        if (interactive && selected) ...[
          Positioned(
            left: _pad + w - 14,
            top: _padTop + h - 14,
            child: ElementDragDetector(
              key: const ValueKey('image-resize'),
              onDragUpdate: onResize,
              onDragEnd: onChangeEnd,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.onPrimary, width: 2),
                ),
                child: Icon(Icons.open_in_full, size: 14, color: scheme.onPrimary),
              ),
            ),
          ),
          Positioned(
            left: _pad,
            // above the picture, or inside it when there is no room above
            top: item.position.dy < 48 ? _padTop + 4 : _padTop - 44,
            child: Material(
              elevation: 3,
              shape: const StadiumBorder(),
              color: scheme.surface,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (onEdit != null)
                  IconButton(
                    key: const ValueKey('image-edit'),
                    icon: const Icon(Icons.tune),
                    tooltip: tr('Edit picture'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onEdit,
                  ),
                if (onPalette != null)
                  IconButton(
                    key: const ValueKey('image-palette'),
                    icon: const Icon(Icons.palette_outlined),
                    tooltip: tr('Take colours from this picture for the pen'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onPalette,
                  ),
                if (onReference != null)
                  IconButton(
                    key: const ValueKey('image-reference'),
                    icon: const Icon(Icons.layers_outlined),
                    tooltip: tr('Use as a reference to trace: faded and locked, under the drawing'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onReference,
                  ),
                if (onDuplicate != null)
                  IconButton(
                    key: const ValueKey('image-duplicate'),
                    icon: const Icon(Icons.copy_all_outlined),
                    tooltip: tr('Duplicate picture'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onDuplicate,
                  ),
                IconButton(
                  key: const ValueKey('image-delete'),
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  tooltip: tr('Delete picture'),
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                ),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  static const double _pad = 24;
  static const double _padTop = 52;
}
