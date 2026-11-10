import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The pages of a note, in a list that is told how tall each one is ([extents]) instead of finding out from those it has built.
///
/// A list that finds out keeps the pages it has built where they were when their size changes, and so does not show the pages it should
/// after a zoom, and it can only guess where it ends: with one long document in it, far off.
class PageList extends SliverVariedExtentList {
  PageList({super.key, required this.extents, required super.itemBuilder})
    : super.builder(itemCount: extents.length, itemExtentBuilder: (index, _) => index < extents.length ? extents[index] : null);

  final List<double> extents;

  double get _total => extents.fold(0.0, (a, b) => a + b);

  @override
  RenderSliverVariedExtentList createRenderObject(BuildContext context) =>
      _RenderPageList(childManager: context as SliverMultiBoxAdaptorElement, itemExtentBuilder: itemExtentBuilder, total: _total);

  @override
  void updateRenderObject(BuildContext context, RenderSliverVariedExtentList renderObject) {
    super.updateRenderObject(context, renderObject);
    (renderObject as _RenderPageList).total = _total;
  }
}

class _RenderPageList extends RenderSliverVariedExtentList {
  _RenderPageList({required super.childManager, required super.itemExtentBuilder, required this.total});

  double total;

  // (the list this comes from asks for a guess even though it could add the heights up)
  @override
  double estimateMaxScrollOffset(SliverConstraints constraints, {int? firstIndex, int? lastIndex, double? leadingScrollOffset, double? trailingScrollOffset}) => total;
}
