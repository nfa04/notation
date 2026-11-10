import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/language.dart';
import '../models/stamps.dart';
import '../painters/canvas_painters.dart';
import '../style/platform_dialog.dart';

/// The stamps of the library: a tap on one chooses it (the dialog answers with it), the bin takes it out of the library.
class StampsDialog extends StatelessWidget {
  final StampLibrary library;

  const StampsDialog({super.key, required this.library});

  @override
  Widget build(BuildContext context) {
    return PlatformAlertDialog(
      title: Text(tr('Stamps')),
      content: SizedBox(width: 460, child: StampsGrid(library: library, onPick: (s) => Navigator.pop(context, s))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
    );
  }
}

/// The stamps beside the note (on a wide screen): a tap puts a stamp on the page and the library stays open, for the next one.
class StampsPanel extends StatelessWidget {
  final StampLibrary library;

  /// Counts up when a stamp was added to the library, so that the panel reads it again.
  final Listenable? changed;
  final ValueChanged<Stamp> onPick;
  final VoidCallback onClose;

  const StampsPanel({super.key, required this.library, this.changed, required this.onPick, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(children: [
            Expanded(child: Text(tr('Stamps'), style: Theme.of(context).textTheme.titleMedium)),
            IconButton(key: const ValueKey('stamps-close'), tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: onClose),
          ]),
        ),
        Expanded(child: Padding(padding: const EdgeInsets.all(12), child: StampsGrid(library: library, onPick: onPick, changed: changed))),
      ]),
    );
  }
}

/// The thumbnails of the stamps in the library, read when it is built and again when [changed] says so.
class StampsGrid extends StatefulWidget {
  final StampLibrary library;
  final ValueChanged<Stamp> onPick;
  final Listenable? changed;

  const StampsGrid({super.key, required this.library, required this.onPick, this.changed});

  @override
  State<StampsGrid> createState() => _StampsGridState();
}

class _StampsGridState extends State<StampsGrid> {
  List<Stamp>? _stamps;

  @override
  void initState() {
    super.initState();
    widget.changed?.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(StampsGrid old) {
    super.didUpdateWidget(old);
    if (old.changed != widget.changed) {
      old.changed?.removeListener(_load);
      widget.changed?.addListener(_load);
    }
  }

  @override
  void dispose() {
    widget.changed?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final stamps = await widget.library.load();
    if (mounted) setState(() => _stamps = stamps);
  }

  Future<void> _remove(Stamp s) async {
    await widget.library.remove(s.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final stamps = _stamps;
    final scheme = Theme.of(context).colorScheme;
    return stamps == null
        ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator.adaptive()))
        : stamps.isEmpty
            ? Text(tr('No stamps yet. Select some drawings and use "Save as a stamp" to keep them here.'))
            : SingleChildScrollView(
                child: Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final s in stamps)
                    SizedBox(
                      width: 104,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Stack(children: [
                          InkWell(
                            key: ValueKey('stamp-${s.id}'),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => widget.onPick(s),
                            child: Container(
                              width: 104,
                              height: 104,
                              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.all(8),
                              child: CustomPaint(painter: StampPainter(s)),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: IconButton(
                              key: ValueKey('stamp-delete-${s.id}'),
                              tooltip: tr('Remove this stamp'),
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              icon: const Icon(Icons.close),
                              onPressed: () => _remove(s),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 2),
                        Text(s.name.isEmpty ? tr('Stamp') : s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      ]),
                    ),
                ]),
              );
  }
}

/// A stamp drawn as large as fits the space it is given.
class StampPainter extends CustomPainter {
  final Stamp stamp;

  const StampPainter(this.stamp);

  @override
  void paint(Canvas canvas, Size size) {
    final box = stamp.bounds;
    if (stamp.strokes.isEmpty) return;
    final scale = math.min(size.width / math.max(1.0, box.width), size.height / math.max(1.0, box.height));
    canvas
      ..translate((size.width - box.width * scale) / 2, (size.height - box.height * scale) / 2)
      ..scale(scale);
    paintStrokes(canvas, stamp.strokes, 0.6);
  }

  @override
  bool shouldRepaint(covariant StampPainter old) => old.stamp != stamp;
}
