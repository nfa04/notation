import '../util/apart.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;
import 'package:image/image.dart' as img;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../scan/doc_scan.dart';
import '../scan/ocr_service.dart';
import '../style/platform_dialog.dart';

/// What scanning a page made.
class ScanResult {
  /// The straightened, cleaned page as a picture file (JPEG, or PNG for black and white).
  final Uint8List page;
  final bool isPng;

  /// The text read from it, if that was asked for.
  final String? text;
  const ScanResult(this.page, this.isPng, this.text);
}

/// Shows the picture [photo]; the person puts the four corners on the page, picks a look, and gets the page back straight. With
/// [ocr] installed it can read the text too.
Future<ScanResult?> scanPage(BuildContext context, Uint8List photo, {OcrService? ocr}) =>
    Navigator.of(context).push<ScanResult>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => ScanScreen(photo: photo, ocr: ocr)));

/// Only the text of a picture, no scanning of the page.
Future<String?> readTextOf(BuildContext context, Uint8List photo, OcrService ocr) => showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReadingDialog(photo: photo, ocr: ocr),
    );

// The work on pictures is done on another isolate. These are top-level so that what is sent over holds nothing of a widget.

Future<img.Image?> _decodePhoto(Uint8List bytes) => runApart(() {
      var image = img.decodeImage(bytes);
      if (image == null) return null;
      image = img.bakeOrientation(image);
      // a photograph from a camera is bigger than the page needs to be
      if (image.width > 3000 || image.height > 3000) {
        image = image.width >= image.height ? img.copyResize(image, width: 3000) : img.copyResize(image, height: 3000);
      }
      return image;
    });

Future<Uint8List> _previewOf(img.Image image) => runApart(() {
      final wide = image.width >= image.height;
      return Uint8List.fromList(img.encodeJpg(img.copyResize(image, width: wide ? 1400 : null, height: wide ? null : 1400), quality: 85));
    });

Future<img.Image> _rotated(img.Image image, int quarterTurns) => runApart(() => img.copyRotate(image, angle: quarterTurns * 90));

Future<(Uint8List, bool)> _makePage(img.Image source, List<Offset> corners, ScanFilter filter) => runApart(() {
      final page = applyFilter(straightenPage(source, corners), filter);
      final png = filter == ScanFilter.blackWhite;
      return (png ? Uint8List.fromList(img.encodePng(page)) : Uint8List.fromList(img.encodeJpg(page, quality: 88)), png);
    });

/// Shows a photo of a page with the text found in it, to be corrected and put into a note.
class ScanScreen extends StatefulWidget {
  final Uint8List photo;
  final OcrService? ocr;
  const ScanScreen({super.key, required this.photo, this.ocr});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  img.Image? _source;
  Uint8List? _shown;
  List<Offset> _corners = const [Offset(0.05, 0.05), Offset(0.95, 0.05), Offset(0.95, 0.95), Offset(0.05, 0.95)];
  ScanFilter _filter = ScanFilter.clean;
  bool _read = false;
  bool _busy = true;
  String? _error;
  String? _status;
  bool _gone = false;

  bool get _canRead => widget.ocr?.installed ?? false;

  @override
  void initState() {
    super.initState();
    _read = _canRead;
    _open();
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final decoded = await _decodePhoto(widget.photo);
      if (decoded == null) throw const FormatException('That is not a picture.');
      _setSource(decoded);
    } catch (e) {
      if (!_gone) {
        setState(() {
          _busy = false;
          _error = tr('Could not open the picture: {error}', {'error': e});
        });
      }
    }
  }

  Future<void> _setSource(img.Image image) async {
    final jpeg = await _previewOf(image);
    if (_gone) return;
    setState(() {
      _source = image;
      _shown = jpeg;
      _corners = findPageCorners(image);
      _busy = false;
    });
  }

  Future<void> _rotate(int quarterTurns) async {
    final source = _source;
    if (source == null) return;
    setState(() => _busy = true);
    final turned = await _rotated(source, quarterTurns);
    await _setSource(turned);
  }

  Future<void> _done() async {
    final source = _source;
    if (source == null) return;
    setState(() {
      _busy = true;
      _status = tr('Straightening the page...');
    });
    try {
      final made = await _makePage(source, _corners, _filter);
      String? text;
      if (_read && _canRead) {
        setState(() => _status = tr('Reading the text...'));
        final result = await widget.ocr!.recognize(made.$1);
        text = result.text;
      }
      if (!mounted) return;
      Navigator.pop(context, ScanResult(made.$1, made.$2, text));
    } catch (e) {
      if (!_gone) {
        setState(() {
          _busy = false;
          _status = null;
          _error = tr('Could not scan the page: {error}', {'error': e});
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan a page'),
        actions: [
          IconButton(key: const ValueKey('scan-rotate-left'), tooltip: tr('Turn left'), icon: const Icon(Icons.rotate_left), onPressed: _busy ? null : () => _rotate(-1)),
          IconButton(key: const ValueKey('scan-rotate-right'), tooltip: tr('Turn right'), icon: const Icon(Icons.rotate_right), onPressed: _busy ? null : () => _rotate(1)),
          IconButton(
            key: const ValueKey('scan-detect'),
            tooltip: tr('Find the page again'),
            icon: const Icon(Icons.auto_fix_high),
            onPressed: _busy || _source == null ? null : () => setState(() => _corners = findPageCorners(_source!)),
          ),
          const SizedBox(width: 8),
          FilledButton(key: const ValueKey('scan-done'), onPressed: _busy || _source == null ? null : _done, child: const Text('Done')),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text.verbatim(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))))
              : (_shown == null
                  ? const Center(child: CircularProgressIndicator.adaptive(),)
                  : Stack(children: [
                      Positioned.fill(child: _CornerEditor(picture: _shown!, aspect: _source!.width / _source!.height, corners: _corners, onChanged: (c) => setState(() => _corners = c))),
                      if (_busy)
                        Positioned.fill(
                          child: ColoredBox(
                            color: Colors.black38,
                            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                              const CircularProgressIndicator.adaptive(),
                              if (_status != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text.verbatim(_status!, style: const TextStyle(color: Colors.white))),
                            ])),
                          ),
                        ),
                    ])),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final f in ScanFilter.values)
              ChoiceChip(key: ValueKey('scan-filter-${f.name}'), label: Text(f.label), selected: _filter == f, onSelected: (_) => setState(() => _filter = f)),
            const SizedBox(width: 12),
            if (widget.ocr != null)
              Tooltip(
                message: tr(_canRead ? 'Read the text on the page with the text reader' : 'Install the text reader in the settings first'),
                child: FilterChip(
                  key: const ValueKey('scan-read'),
                  avatar: const Icon(Icons.text_snippet_outlined, size: 18),
                  label: const Text('Read the text'),
                  selected: _read && _canRead,
                  onSelected: _canRead ? (v) => setState(() => _read = v) : null,
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// The picture with the four corners of the page on it, to be pulled into place.
class _CornerEditor extends StatelessWidget {
  final Uint8List picture;
  final double aspect;
  final List<Offset> corners;
  final ValueChanged<List<Offset>> onChanged;
  const _CornerEditor({required this.picture, required this.aspect, required this.corners, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // the picture is as big as it can be in the room, and the corners are fractions of it
      var w = box.maxWidth - 32, h = w / aspect;
      if (h > box.maxHeight - 32) {
        h = box.maxHeight - 32;
        w = h * aspect;
      }
      final left = (box.maxWidth - w) / 2, top = (box.maxHeight - h) / 2;
      Offset at(Offset f) => Offset(left + f.dx * w, top + f.dy * h);
      return Stack(children: [
        Positioned(left: left, top: top, width: w, height: h, child: Image.memory(picture, fit: BoxFit.fill, gaplessPlayback: true)),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _QuadPainter([for (final c in corners) at(c)], Rect.fromLTWH(left, top, w, h), Theme.of(context).colorScheme.primary)))),
        for (var i = 0; i < 4; i++)
          Positioned(
            left: at(corners[i]).dx - 24,
            top: at(corners[i]).dy - 24,
            width: 48,
            height: 48,
            child: GestureDetector(
              key: ValueKey('scan-corner-$i'),
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) {
                final p = at(corners[i]) + d.delta;
                final next = [...corners];
                next[i] = Offset(((p.dx - left) / w).clamp(0.0, 1.0), ((p.dy - top) / h).clamp(0.0, 1.0));
                onChanged(next);
              },
              child: Center(
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.85), border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3)),
                ),
              ),
            ),
          ),
      ]);
    });
  }
}

class _QuadPainter extends CustomPainter {
  final List<Offset> quad;
  final Rect picture;
  final Color color;
  _QuadPainter(this.quad, this.picture, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addPolygon(quad, true);
    // what is outside the page is dimmed
    final outside = Path.combine(PathOperation.difference, Path()..addRect(picture), path);
    canvas.drawPath(outside, Paint()..color = Colors.black45);
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(_QuadPainter old) => old.quad.toString() != quad.toString() || old.picture != picture;
}

class _ReadingDialog extends StatefulWidget {
  final Uint8List photo;
  final OcrService ocr;
  const _ReadingDialog({required this.photo, required this.ocr});

  @override
  State<_ReadingDialog> createState() => _ReadingDialogState();
}

class _ReadingDialogState extends State<_ReadingDialog> {
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.ocr.recognize(widget.photo, progress: (v) {
      if (mounted) setState(() => _progress = v);
    }).then((page) {
      if (mounted) Navigator.pop(context, page.text);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Reading the text'),
        content: _error != null ? Text.verbatim(_error!) : LinearProgressIndicator(value: _progress > 0 ? _progress : null),
        actions: [if (_error != null) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      );
}
