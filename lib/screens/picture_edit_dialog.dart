import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../images/picture_edit.dart';
import '../images/subject_service.dart';
import '../ink/ink_recognizer.dart' show HandwritingStatus;
import '../l10n/language.dart';
import '../style/platform_dialog.dart';

/// Makes [edit] of [source] (a small copy of the picture, for showing); runs in an isolate by default.
typedef PictureRenderer = Future<RgbaPicture> Function(RgbaPicture source, PictureEdit edit, SubjectMatte? subject);

Future<RgbaPicture> _renderInIsolate(RgbaPicture source, PictureEdit edit, SubjectMatte? subject) => compute(renderPicture, (source, edit, subject));

/// Makes the small copy of the picture that is shown while it is edited; runs in an isolate by default (decoding a photograph of many
/// megapixels in Dart takes seconds on a tablet, and would stop the screen).
typedef PictureDecoder = Future<RgbaPicture?> Function(Uint8List source);

Future<RgbaPicture?> _decodeInIsolate(Uint8List source) => compute(_decodePreview, source);

RgbaPicture? _decodePreview(Uint8List source) => decodePicture(source, maxSide: pictureEditPreviewSide);

/// How large the copy of the picture that is shown while it is edited is, on its longest side.
const int pictureEditPreviewSide = 480;

/// What the panel answers: the edit (not the picture; the editor makes that from the original, at full size) and, when the subject
/// of the picture is to be found, what the model said of it.
class PictureEditResult {
  final PictureEdit edit;
  final SubjectMatte? subject;
  const PictureEditResult(this.edit, this.subject);
}

/// Edits a picture: turn, flip, crop, colours, filters and the background, with the result shown at once. It answers a
/// [PictureEditResult], or null if it was cancelled.
class PictureEditDialog extends StatefulWidget {
  /// The picture as it is stored (PNG, JPEG...).
  final Uint8List source;

  /// What shows the edit: replaced in tests, which have no isolates to wait for.
  final PictureRenderer renderer;

  /// Makes the small copy that is shown: replaced in tests, like [renderer].
  final PictureDecoder decoder;

  /// Finds the subject of the picture; null: that is not offered.
  final SubjectService? subject;

  /// Set when the editing stands beside the note (a panel, not a dialog): it is told what was made when the person applies it, or null
  /// when they let it go.
  final ValueChanged<PictureEditResult?>? onDone;

  const PictureEditDialog({super.key, required this.source, this.renderer = _renderInIsolate, this.decoder = _decodeInIsolate, this.subject, this.onDone});

  @override
  State<PictureEditDialog> createState() => _PictureEditDialogState();
}

class _PictureEditDialogState extends State<PictureEditDialog> {
  RgbaPicture? _small;
  PictureEdit _edit = PictureEdit.none;
  RgbaPicture? _shown;
  ui.Image? _image;
  bool _broken = false;
  int _generation = 0;

  /// What the model said of the picture (once it was asked), whether it is being asked, and whether it said anything.
  SubjectMatte? _matte;
  bool _finding = false;
  bool _noSubject = false;
  Timer? _later;

  @override
  void initState() {
    super.initState();
    widget.subject?.addListener(_ensureMatte);
    _open();
  }

  /// The dialog is up at once (with a spinner where the picture will be); the picture is decoded apart from the screen.
  Future<void> _open() async {
    RgbaPicture? small;
    try {
      small = await widget.decoder(widget.source);
    } catch (_) {
      small = null; // (a file that is cut off can make the decoder fail instead of answering null)
    }
    if (!mounted) return;
    if (small == null) {
      setState(() => _broken = true);
    } else {
      _small = small;
      _render();
      _ensureMatte(); // (the subject may have been asked for before the picture was there)
    }
  }

  @override
  void dispose() {
    widget.subject?.removeListener(_ensureMatte);
    _later?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _set(PictureEdit edit) {
    setState(() => _edit = edit);
    _later?.cancel();
    _later = Timer(const Duration(milliseconds: 120), _render);
    _ensureMatte();
  }

  /// Asks the model about the picture, once, when its subject is wanted and the model is there.
  Future<void> _ensureMatte() async {
    final service = widget.subject, small = _small;
    if (service == null || small == null || _matte != null || _finding || _edit.background != BackgroundRemoval.subject || !service.installed) return;
    setState(() {
      _finding = true;
      _noSubject = false;
    });
    SubjectMatte? matte;
    try {
      matte = await service.find(small);
    } catch (_) {
      matte = null;
    }
    if (!mounted) return;
    setState(() {
      _finding = false;
      _matte = matte;
      _noSubject = matte == null;
    });
    _render();
  }

  Future<void> _render() async {
    final small = _small;
    if (small == null) return;
    final generation = ++_generation;
    final picture = await widget.renderer(small, _edit, _matte);
    if (!mounted || generation != _generation) return; // (a newer change is on its way)
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(picture.rgba, picture.width, picture.height, ui.PixelFormat.rgba8888, done.complete);
    final image = await done.future;
    if (!mounted || generation != _generation) {
      image.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
      _shown = picture;
    });
  }

  /// The colour of the picture where the picture shown was tapped (of its pixel, see-through or not).
  void _pick(Offset local, Size box) {
    final shown = _shown;
    if (shown == null || _edit.background == BackgroundRemoval.none || _edit.background == BackgroundRemoval.subject) return;
    final scale = (box.width / shown.width) < (box.height / shown.height) ? box.width / shown.width : box.height / shown.height;
    final w = shown.width * scale, h = shown.height * scale;
    final x = ((local.dx - (box.width - w) / 2) / scale).floor(), y = ((local.dy - (box.height - h) / 2) / scale).floor();
    if (x < 0 || y < 0 || x >= shown.width || y >= shown.height) return;
    final (r, g, b, _) = shown.pixel(x, y);
    _set(_edit.copyWith(backgroundColor: 0xFF000000 | r << 16 | g << 8 | b));
  }

  Widget _slider(String key, String label, double value, double min, double max, ValueChanged<double> onChanged, {String? text}) => Row(children: [
        SizedBox(width: 92, child: Text(tr(label), style: Theme.of(context).textTheme.bodySmall)),
        Expanded(child: Slider.adaptive(key: ValueKey(key), value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
        SizedBox(width: 40, child: Text(text ?? '${(value * 100).round()}', textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall)),
      ]);

  Widget _title(String text) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 2), child: Text(tr(text), style: Theme.of(context).textTheme.titleSmall));

  /// What goes with "Find the subject": the model to download, or how it did and the sliders.
  Widget _subjectOptions(PictureEdit e) {
    final service = widget.subject!;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (!service.installed) {
          final downloading = service.status == HandwritingStatus.downloading;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Finding the subject needs a small model ({size} MB), which is downloaded once and runs on this device.', {'size': service.sizeMb}), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            if (downloading)
              LinearProgressIndicator(key: const ValueKey('pe-subject-progress'), value: service.progress > 0 ? service.progress : null)
            else
              Row(children: [
                FilledButton.tonal(key: const ValueKey('pe-subject-download'), onPressed: service.install, child: Text(tr('Download'))),
                if (service.error != null) Expanded(child: Padding(padding: const EdgeInsets.only(left: 8), child: Text(service.error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)))),
              ]),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_finding) Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2)), const SizedBox(width: 8), Text(tr('Looking for the subject...'), style: Theme.of(context).textTheme.bodySmall)]),
          if (_noSubject) Text(tr('The subject could not be found in this picture.'), key: const ValueKey('pe-subject-none'), style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          _slider('pe-subject-cut', 'How sure', e.subjectCut, 0.05, 0.95, (v) => _set(e.copyWith(subjectCut: v))),
          _slider('pe-softness', 'Soft edge', e.softness, 0, 0.3, (v) => _set(e.copyWith(softness: v))),
        ]);
      },
    );
  }

  bool get _inPanel => widget.onDone != null;

  /// Hands the answer over: the dialog is closed with it, a panel tells whoever opened it.
  void _finish(PictureEditResult? answer) => _inPanel ? widget.onDone!(answer) : Navigator.pop(context, answer);

  VoidCallback? _applyAction(PictureEdit e) => _broken || e.isNone || (e.background == BackgroundRemoval.subject && _matte == null) // (the subject has to be found first)
      ? null
      : () => _finish(PictureEditResult(e, e.background == BackgroundRemoval.subject ? _matte : null));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = _edit;
    if (_inPanel) {
      return Material(
        color: scheme.surface,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(children: [
              Expanded(child: Text(tr('Edit picture'), style: Theme.of(context).textTheme.titleMedium)),
              IconButton(key: const ValueKey('pe-close'), tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: () => _finish(null)),
            ]),
          ),
          Expanded(child: _broken ? Padding(padding: const EdgeInsets.all(16), child: Text(tr('This picture cannot be opened.'))) : SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 16), child: _body(scheme, e))),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(key: const ValueKey('pe-cancel'), onPressed: () => _finish(null), child: Text(tr('Cancel'))),
              FilledButton(key: const ValueKey('pe-apply'), onPressed: _applyAction(e), child: Text(tr('Apply'))),
            ]),
          ),
        ]),
      );
    }
    return PlatformAlertDialog(
      title: Text(tr('Edit picture')),
      content: SizedBox(
        width: math.min(520, MediaQuery.sizeOf(context).width - 112), // (a phone's width less the dialog's margins)
        child: _broken ? Text(tr('This picture cannot be opened.')) : SingleChildScrollView(child: _body(scheme, e)),
      ),
      actions: [
        TextButton(key: const ValueKey('pe-cancel'), onPressed: () => _finish(null), child: Text(tr('Cancel'))),
        FilledButton(key: const ValueKey('pe-apply'), onPressed: _applyAction(e), child: Text(tr('Apply'))),
      ],
    );
  }

  Widget _body(ColorScheme scheme, PictureEdit e) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      // what it looks like, on a checkerboard so that what is see-through shows
      Center(
        child: Container(
          key: const ValueKey('pe-preview'),
          width: _inPanel ? double.infinity : math.min(360, MediaQuery.sizeOf(context).width - 112),
          height: 240,
          decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant)),
          child: LayoutBuilder(
            builder: (context, box) => GestureDetector(
              behavior: HitTestBehavior.opaque, // (a picture does not take taps by itself)
              onTapDown: (d) => _pick(d.localPosition, box.biggest),
              child: CustomPaint(
                painter: _CheckerPainter(scheme.surfaceContainerHighest, scheme.surface),
                child: _image == null ? const Center(child: CircularProgressIndicator.adaptive()) : RawImage(image: _image, fit: BoxFit.contain, width: box.maxWidth, height: box.maxHeight),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 4, alignment: WrapAlignment.center, children: [
        IconButton(key: const ValueKey('pe-rotate-left'), tooltip: tr('Turn left'), icon: const Icon(Icons.rotate_left), onPressed: () => _set(e.copyWith(turns: e.turns + 3))),
        IconButton(key: const ValueKey('pe-rotate-right'), tooltip: tr('Turn right'), icon: const Icon(Icons.rotate_right), onPressed: () => _set(e.copyWith(turns: e.turns + 1))),
        IconButton(key: const ValueKey('pe-flip-h'), tooltip: tr('Flip left to right'), isSelected: e.flipHorizontal, icon: const Icon(Icons.flip), onPressed: () => _set(e.copyWith(flipHorizontal: !e.flipHorizontal))),
        IconButton(
            key: const ValueKey('pe-flip-v'),
            tooltip: tr('Flip top to bottom'),
            isSelected: e.flipVertical,
            icon: const RotatedBox(quarterTurns: 1, child: Icon(Icons.flip)),
            onPressed: () => _set(e.copyWith(flipVertical: !e.flipVertical))),
        TextButton(key: const ValueKey('pe-reset'), onPressed: e.isNone ? null : () => _set(PictureEdit.none), child: Text(tr('Reset'))),
      ]),
      _title('Crop'),
      _slider('pe-crop-left', 'Left', e.cropLeft, 0, 0.9, (v) => _set(e.copyWith(cropLeft: v))),
      _slider('pe-crop-top', 'Top', e.cropTop, 0, 0.9, (v) => _set(e.copyWith(cropTop: v))),
      _slider('pe-crop-right', 'Right', e.cropRight, 0, 0.9, (v) => _set(e.copyWith(cropRight: v))),
      _slider('pe-crop-bottom', 'Bottom', e.cropBottom, 0, 0.9, (v) => _set(e.copyWith(cropBottom: v))),
      _title('Colours'),
      _slider('pe-brightness', 'Brightness', e.brightness, -1, 1, (v) => _set(e.copyWith(brightness: v))),
      _slider('pe-contrast', 'Contrast', e.contrast, -1, 1, (v) => _set(e.copyWith(contrast: v))),
      _slider('pe-saturation', 'Saturation', e.saturation, -1, 1, (v) => _set(e.copyWith(saturation: v))),
      _title('Filter'),
      Wrap(spacing: 6, children: [
        for (final f in PictureFilter.values)
          ChoiceChip(key: ValueKey('pe-filter-${f.name}'), label: Text(tr(f.label)), selected: e.filter == f, onSelected: (_) => _set(e.copyWith(filter: f))),
      ]),
      _title('Background'),
      Wrap(spacing: 6, children: [
        for (final b in BackgroundRemoval.values)
          if (b != BackgroundRemoval.subject || widget.subject != null)
          ChoiceChip(key: ValueKey('pe-bg-${b.name}'), label: Text(tr(b.label)), selected: e.background == b, onSelected: (_) => _set(e.copyWith(background: b))),
      ]),
      if (e.background == BackgroundRemoval.subject) _subjectOptions(e),
      if (e.background != BackgroundRemoval.none && e.background != BackgroundRemoval.subject) ...[
        _slider('pe-tolerance', 'How much', e.tolerance, 0, 0.6, (v) => _set(e.copyWith(tolerance: v))),
        _slider('pe-softness', 'Soft edge', e.softness, 0, 0.3, (v) => _set(e.copyWith(softness: v))),
        Row(children: [
          Container(
            key: const ValueKey('pe-colour'),
            width: 20,
            height: 20,
            decoration: BoxDecoration(color: e.backgroundColor == null ? null : Color(e.backgroundColor!), border: Border.all(color: scheme.outline)),
            child: e.backgroundColor == null ? const Icon(Icons.auto_awesome, size: 14) : null,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(tr(e.backgroundColor == null ? 'The colour of the edges. Tap the picture to choose another colour.' : 'The colour you chose.'), style: Theme.of(context).textTheme.bodySmall)),
          if (e.backgroundColor != null) TextButton(key: const ValueKey('pe-colour-auto'), onPressed: () => _set(e.copyWith(clearBackgroundColor: true)), child: Text(tr('Edges'))),
        ]),
      ],
    ]);
  }
}

/// A checkerboard, to show through the see-through parts of a picture.
class _CheckerPainter extends CustomPainter {
  final Color a, b;
  _CheckerPainter(this.a, this.b);

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 10.0;
    canvas.drawRect(Offset.zero & size, Paint()..color = b);
    final paint = Paint()..color = a;
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = (y % 2); x * cell < size.width; x += 2) {
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerPainter old) => old.a != a || old.b != b;
}
