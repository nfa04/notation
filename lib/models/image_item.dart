import 'dart:ui';

import 'canvas_models.dart' show baseLayerId, noGroup;

/// A picture placed on a page. The file is a copy in the app's storage.
class ImageItem {
  final String id;
  final String path;
  Offset position;
  Size size;

  /// Who placed it; null if not known.
  String? author;

  /// The layer it is on, by id (see `layers.dart`); a layer that is not there is the base layer.
  String layer;

  /// The group it belongs to ([noGroup] for none), see [DrawingStroke.group].
  String group;

  ImageItem({required this.id, required this.path, required this.position, required this.size, this.author, this.layer = baseLayerId, this.group = noGroup});

  double get aspect => size.width / size.height;
}
