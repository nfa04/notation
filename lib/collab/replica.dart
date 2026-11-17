import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart' show TextEditingValue, TextSelection;

import '../data/note_data.dart';
import '../data/point_codec.dart';
import '../models/canvas_models.dart';
import '../models/connector.dart';
import '../models/image_item.dart';
import '../models/bezier.dart';
import '../models/brush_desc.dart';
import '../models/gradient.dart';
import '../models/stroke_label.dart';
import '../models/layers.dart';
import '../models/page_background.dart';
import '../models/page_format.dart';
import '../models/pdf_models.dart';
import '../models/rich_text.dart';
import 'text_crdt.dart';
import 'text_diff.dart';

/// Which of two changes to one thing is the later: a counter that every device moves
/// past whatever it has seen (a Lamport clock), the device's name breaking a tie. All
/// devices come to the same answer, whatever order the changes reach them in.
class Version implements Comparable<Version> {
  final int clock;
  final String site;

  const Version(this.clock, this.site);

  @override
  int compareTo(Version other) => clock != other.clock ? clock.compareTo(other.clock) : site.compareTo(other.site);

  bool operator >(Version o) => compareTo(o) > 0;
  bool operator >=(Version o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) => other is Version && other.clock == clock && other.site == site;

  @override
  int get hashCode => Object.hash(clock, site);

  List<Object> toJson() => [clock, site];

  static Version fromJson(Object? json) {
    final l = json as List;
    return Version((l[0] as num).toInt(), l[1] as String);
  }

  @override
  String toString() => '$clock@$site';
}

/// What a change is about. [note] is the note's own settings: `title`, `setup` (the look of its
/// pages) and `doc` (the written document).
enum ElementKind { stroke, box, image, mark, note }

/// One change: element [id] of [kind] now has [data] (or is gone, if [deleted]), as of [version].
/// Every change replaces the element as a whole, and the later one wins ([Version]).
class CollabOp {
  final ElementKind kind;
  final String id;
  final Version version;
  final bool deleted;

  /// How often the element came back after being deleted (an erase that was taken back). A
  /// change to an element that has been deleted, made by someone who had not seen that, cannot
  /// undo the deletion; coming back is a decision, and has the next generation.
  final int generation;
  final Map<String, Object?> data;

  const CollabOp(this.kind, this.id, this.version, {this.deleted = false, this.generation = 0, this.data = const {}});

  Map<String, Object?> toJson() => {
        'k': kind.name,
        'i': id,
        'v': version.toJson(),
        if (generation > 0) 'g': generation,
        if (deleted) 'x': true,
        if (!deleted) 'd': data,
      };

  static CollabOp? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = ElementKind.values.where((k) => k.name == json['k']).firstOrNull;
    if (kind == null || json['i'] is! String) return null; // from a newer version of the app: ignored
    // (a note file keeps an id in at most 255 bytes: a longer one would make the file it is saved in unreadable)
    if (utf8.encode(json['i'] as String).length > 255) return null;
    return CollabOp(
      kind,
      json['i'] as String,
      Version.fromJson(json['v']),
      deleted: json['x'] == true,
      generation: (json['g'] as num?)?.toInt() ?? 0,
      data: ((json['d'] as Map?) ?? const {}).cast<String, Object?>(),
    );
  }
}

class _Known {
  Version version;
  bool deleted;
  int generation;
  int fingerprint;

  /// Where a box is and how it looks, part by part (see [Replica._boxParts]): what each part was as of the last time it was sent or taken
  /// in, and the version of the change that last made it different. Each part is changed on its own: somebody who only types, or moves
  /// the box, does not undo what another did to its other parts at the same time.
  Map<String, int> partSig = const {};
  Map<String, Version> partVer = const {};

  /// Set when something here was changed that the fingerprint does not show (a part kept against a later change of somebody else's).
  bool dirty = false;

  _Known(this.version, this.deleted, this.fingerprint, [this.generation = 0]);

  /// Whether a change replaces what is known: a later generation does; in one generation a
  /// deletion beats any change, and otherwise the later version wins.
  bool replacedBy(CollabOp op) {
    if (op.generation != generation) return op.generation > generation;
    if (op.deleted != deleted) return op.deleted;
    return op.version > version;
  }
}

/// Makes a text box that the editor has hooked up (its listeners, its saving).
typedef BoxMaker = TextBoxWidgetModel Function(String id);

/// The longest picture (as base64 text, about 24 MB of picture) that is taken from another device in a live session.
const maxPeerImageBase64 = 32 * 1024 * 1024;

/// Puts the bytes of a picture that came from another device into a file; returns its path.
typedef ImageSaver = String Function(String id, Uint8List bytes, String extension);

/// Hands the changes to the note's own settings to whoever owns them.
typedef NoteFieldSink = void Function(String field, Map<String, Object?> data);

/// One device's view of a note that several devices edit at the same time.
///
/// The note itself is the editor's ordinary data. The replica remembers, for each stroke, box,
/// picture and mark, which version it is at and what it looked like then, so that
///  - [localChanges] finds what the person here changed since (as [CollabOp]s to send), and
///  - [apply] takes in what others changed, unless this device has something later already.
/// A deleted element is remembered as deleted, so that a late change to it does not bring it back.
class Replica {
  final String site;
  int _clock;
  final Map<String, _Known> _known = {};

  /// The text of every box and of the written document, as characters that can be put together (see [TextCrdt]), by `kind:id`.
  final Map<String, TextCrdt> _texts = {};

  /// [clock] to carry on from another replica of the same device.
  Replica(this.site, {int clock = 0}) : _clock = clock;

  /// Strokes that are still being drawn here: not a change of the note yet (the others see them as wet ink, see `wet_ink.dart`), and
  /// left out of [localChanges] until the pen is lifted.
  final Set<String> holdBack = {};

  /// Whether a change of a text also carries it as plain text (`text`, `spans`, which every device can read; one that does not merge texts
  /// - an older version of the app - reads only that). A session turns it off when every device it sends to merges them (see
  /// `CollabSession.protocolVersion`): a long document then does not go whole with each key.
  bool wholeTexts = true;

  /// Whether the characters of texts are sent and merged. False: only whole texts, and the last change of a text wins - as an app of an
  /// older version does (a session whose host is one: see `CollabSession.protocolVersion`; and the tests, to play such an app).
  bool mergesTexts = true;

  /// Whether this device is the one every change passes through (the host): a change of a text from a device that does not merge texts
  /// is then made into a change of its characters here (as if the person here had typed it), which goes to the others; on the others it
  /// replaces the text, as it does on that device.
  bool translatesWholeTexts = false;

  int get clock => _clock;

  Version _tick() => Version(++_clock, site);

  static String _key(ElementKind kind, String id) => '${kind.name}:$id';

  // ---- what an element looks like, as data and as a fingerprint

  static List<Map<String, Object>> _spans(List<TextSpanAttribute> spans) => [
        for (final s in spans) {'s': s.start, 'e': s.end, 't': s.type.name, if (s.value != null) 'v': s.value!},
      ];

  static List<TextSpanAttribute> _spansFrom(Object? json) => [
        for (final m in (json is List ? json : const []).whereType<Map>())
          if (AttributeType.values.where((t) => t.name == m['t']).firstOrNull case final type?)
            TextSpanAttribute(start: (m['s'] as num).toInt(), end: (m['e'] as num).toInt(), type: type, value: m['v'] is String ? m['v'] as String : null),
      ];

  static int _hashSpans(List<TextSpanAttribute> spans) => Object.hashAll([for (final s in spans) s.fingerprint]);

  static Map<String, Object?> _strokeData(DrawingStroke s, int page) =>
      {
        'p': page,
        'c': s.color.toARGB32(),
        'w': s.width,
        'pts': base64Encode(encodePoints(s.points)),
        if (s.dash != StrokeDash.solid) 'd': s.dash.index,
        if (s.fill != null) 'f': s.fill!.toARGB32(),
        if (s.pressures != null) 'pr': base64Encode(s.pressures!),
        if (s.brush != penBrushId) 'b': s.brush,
        // (a designed brush goes along with its numbers: a device that never had it draws the line as it was made)
        if (CustomBrushes.of(s.brush) case final desc?) 'bd': desc.toCompactJson(),
        if (s.layer != baseLayerId) 'ly': s.layer,
        if (s.author != null) 'a': s.author,
        if (s.link != null) 'ln': s.link!.toJson(),
        if (s.group != noGroup) 'gr': s.group,
        if (s.curve != null) 'cv': s.curve!.encode(),
        if (s.gradient != null) 'gd': s.gradient!.encode(),
        if (s.label != null) 'lb': s.label!.encode(),
      };
  static int _strokePrint(DrawingStroke s, int page) => Object.hash(page, s.stamp);

  static Map<String, Object?> _boxData(TextBoxWidgetModel b, int page) => {
        'p': page,
        'x': b.position.dx,
        'y': b.position.dy,
        'w': b.size.width,
        'h': b.size.height,
        'fs': b.fontSize,
        'text': b.text,
        'spans': _spans(b.attributes),
        if (!b.style.isDefault) 'style': b.style.toJson(),
        if (b.author != null) 'a': b.author,
        if (b.layer != baseLayerId) 'ly': b.layer,
        if (b.group != noGroup) 'gr': b.group,
      };
  /// The parts of a box that are changed each on their own (see [_Known.partSig]): where it is, its size, the size of its letters, its
  /// look, its layer and its group. (Its text is merged character by character.)
  static Map<String, int> _boxParts(TextBoxWidgetModel b, int page) => {
        'at': Object.hash(page, b.position),
        'size': b.size.hashCode,
        'fs': b.fontSize.hashCode,
        'style': b.style.hashCode,
        'ly': b.layer.hashCode,
        'gr': b.group.hashCode,
      };

  /// Gives [b] the part [part] of a box as [d] says.
  static void _putPart(NoteData note, TextBoxWidgetModel b, String part, Map<String, Object?> d) {
    switch (part) {
      case 'at':
        final page = _page(d);
        if (!(note.textBoxes[page]?.contains(b) ?? false)) {
          for (final list in note.textBoxes.values) {
            list.remove(b);
          }
          note.textBoxes.putIfAbsent(page, () => []).add(b);
        }
        b.position = Offset(_num(d['x'], 0), _num(d['y'], 0));
      case 'size':
        b.size = Size(_num(d['w'], 260), _num(d['h'], 0));
      case 'fs':
        b.fontSize = _num(d['fs'], 16);
      case 'style':
        b.style = TextBoxStyle.fromJson(d['style']);
      case 'ly':
        b.layer = (d['ly'] as String?) ?? baseLayerId;
      case 'gr':
        b.group = (d['gr'] as String?) ?? noGroup;
    }
  }

  /// The versions of the parts of a box that a change says ([json], as `{part: version}`); a part it does not name has [fallback] (a
  /// device that does not keep parts: the version of the change).
  static Map<String, Version> _partVersions(Object? json, Version fallback) => {
        for (final part in const ['at', 'size', 'fs', 'style', 'ly', 'gr'])
          part: (json is Map ? _versionOf(json[part]) : null) ?? fallback,
      };
  static int _boxPrint(TextBoxWidgetModel b, int page) =>
      Object.hash(page, b.position, b.size, b.fontSize, b.style, b.text, _hashSpans(b.attributes), b.layer, b.group);

  static Map<String, Object?> _imageData(ImageItem m, int page) =>
      {'p': page, 'x': m.position.dx, 'y': m.position.dy, 'w': m.size.width, 'h': m.size.height, if (m.author != null) 'a': m.author, if (m.layer != baseLayerId) 'ly': m.layer, if (m.group != noGroup) 'gr': m.group};
  static int _imagePrint(ImageItem m, int page) => Object.hash(page, m.position, m.size, m.layer, m.group);

  static Map<String, Object?> _markData(PdfHighlight h, int page) => {
        'p': page,
        'l': h.rect.left,
        't': h.rect.top,
        'r': h.rect.right,
        'b': h.rect.bottom,
        'c': h.color.toARGB32(),
        if (h.commentBox != null) 'cb': h.commentBox,
        if (h.author != null) 'a': h.author,
      };
  static int _markPrint(PdfHighlight h, int page) => Object.hash(page, h.rect, h.color, h.commentBox);

  static Map<String, Object?> _noteData(NoteData n, String field) => switch (field) {
        'title' => {'title': n.title},
        'setup' => {
            'bg': n.background.name,
            'fmt': n.pageFormat.name,
            'land': n.landscape,
            'nat': (n.nativePages.toList()..sort()),
            'ml': n.marginLeft,
            'mr': n.marginRight,
            'mt': n.marginTop,
            'mb': n.marginBottom,
            'layers': n.layers.toJsonText(),
          },
        _ => {'text': n.documentText, 'spans': _spans(n.documentSpans)},
      };
  static int _notePrint(NoteData n, String field) => switch (field) {
        'title' => n.title.hashCode,
        'setup' => Object.hash(n.background, n.pageFormat, n.landscape, n.marginLeft, n.marginRight, n.marginTop, n.marginBottom, Object.hashAll(n.nativePages.toList()..sort()), n.layers.fingerprint),
        _ => Object.hash(n.documentText, _hashSpans(n.documentSpans)),
      };
  static const noteFields = ['title', 'setup', 'doc'];

  /// Writes the value of a note setting that came in a change into [n].
  static void applyNoteField(NoteData n, String field, Map<String, Object?> d) {
    switch (field) {
      case 'title':
        n.title = d['title'] as String? ?? '';
      case 'setup':
        n.background = PageBackground.values.where((b) => b.name == d['bg']).firstOrNull ?? n.background;
        n.pageFormat = PageFormat.values.where((f) => f.name == d['fmt']).firstOrNull ?? n.pageFormat;
        n.landscape = d['land'] == true;
        final native = d['nat'];
        if (native is List) n.nativePages = {for (final i in native) if (i is num) i.toInt()};
        n.marginLeft = (d['ml'] as num?)?.toDouble() ?? n.marginLeft;
        n.marginRight = (d['mr'] as num?)?.toDouble() ?? n.marginRight;
        n.marginTop = (d['mt'] as num?)?.toDouble() ?? n.marginTop;
        n.marginBottom = (d['mb'] as num?)?.toDouble() ?? n.marginBottom;
        if (d.containsKey('layers')) n.layers = LayerStack.fromJsonText(d['layers'] as String?); // (a device without layers does not say)
      case 'doc':
        n.documentText = d['text'] as String? ?? '';
        n.documentSpans = _spansFrom(d['spans']);
    }
  }

  // ---- the elements of a note, as they would be sent

  /// Every element of [note] with the data it would be sent as (pictures without their bytes), by
  /// `kind:id`. For comparing a note with an earlier state of itself without a [Replica].
  static Map<String, ({ElementKind kind, String id, Map<String, Object?> data})> elementsOf(NoteData note) {
    final out = <String, ({ElementKind kind, String id, Map<String, Object?> data})>{};
    void add(ElementKind kind, String id, Map<String, Object?> data) => out[_key(kind, id)] = (kind: kind, id: id, data: data);
    note.strokes.forEach((page, list) {
      for (final s in list) {
        if (s.points.length >= 2) add(ElementKind.stroke, s.id, _strokeData(s, page));
      }
    });
    note.textBoxes.forEach((page, list) {
      for (final b in list) {
        add(ElementKind.box, b.id, _boxData(b, page));
      }
    });
    note.images.forEach((page, list) {
      for (final m in list) {
        add(ElementKind.image, m.id, _imageData(m, page));
      }
    });
    note.highlights.forEach((page, list) {
      for (final h in list) {
        add(ElementKind.mark, h.id, _markData(h, page));
      }
    });
    for (final f in noteFields) {
      add(ElementKind.note, f, _noteData(note, f));
    }
    return out;
  }

  /// The bytes of the picture at [path]; null if it cannot be read.
  static Uint8List? imageBytes(String path) => _readFile(path);

  /// The file extension a picture is sent with.
  static String imageExtension(String path) => _extension(path);

  /// Where an element key `kind:id` is made.
  static String keyOf(ElementKind kind, String id) => _key(kind, id);

  // ---- text: the characters of a box or of the document, put together from what every device typed

  static const _docKey = 'note:doc';

  /// The formatting of an editor as the text keeps it, and back. Kinds of formatting this version of the app does not know (from a newer
  /// one) are not shown, and not taken away either (see [_synced]).
  static List<MarkSpan> _marksOf(List<TextSpanAttribute> spans) => [for (final s in spans) MarkSpan(s.start, s.end, s.type.name, s.value)];

  static List<TextSpanAttribute> _attributesOf(List<MarkSpan> spans) => [
        for (final s in spans)
          if (AttributeType.values.where((t) => t.name == s.type).firstOrNull case final type?)
            TextSpanAttribute(start: s.start, end: s.end, type: type, value: s.value),
      ];

  static final _knownKinds = {for (final t in AttributeType.values) t.name};

  /// The text of [key] with what the person here changed in [text] and its formatting [spans] taken into it.
  TextCrdt _synced(String key, String text, List<TextSpanAttribute> spans) {
    final crdt = _texts[key] ??= TextCrdt(site);
    crdt.setText(text);
    final unknown = [for (final s in crdt.spans) if (!_knownKinds.contains(s.type)) s];
    crdt.setSpans([..._marksOf(spans), ...unknown]);
    return crdt;
  }

  /// What goes with a text in a change: its characters and formatting (all of it for [whole], else what was changed here since the last
  /// change).
  Map<String, Object?> _textPart(TextCrdt crdt, {required bool whole, bool consume = true}) {
    final tc = whole ? crdt.encode() : (crdt.takeChanges() ?? const <String, Object?>{});
    if (whole && consume) crdt.takeChanges();
    return {'tc': tc};
  }

  /// Puts together what [d] (a change that came in) says of a text with the text as it is here.
  ///
  /// [localText], [localSpans] and [selection] are what the person here sees; what they became after taking in the changes of the others
  /// is in the result. [fresh]: this device had none of the element.
  ({String text, List<TextSpanAttribute> spans, List<int> selection, bool changed}) _merge(
    String key,
    Map<String, Object?> d,
    String localText,
    List<TextSpanAttribute> localSpans,
    List<int> selection, {
    required bool fresh,
  }) {
    final TextCrdt crdt;
    if (fresh) {
      crdt = _texts[key] = TextCrdt(site);
    } else {
      crdt = _synced(key, localText, localSpans);
    }
    final before = crdt.spans;
    final places = fresh ? const <CharId>[] : crdt.placesAt([for (final o in selection) o.clamp(0, crdt.length)]);
    final tc = d['tc'];
    final unrelated = !fresh && tc is Map && tc['all'] == 1 && _unrelated.remove(key);
    final r = unrelated ? crdt.adoptUnrelated(tc) : crdt.merge(tc);
    if (r.lost > 0) debugLog?.call('[live] $key: ${r.lost} characters came after ones that were collected, and have no place');
    final text = crdt.text;
    final spans = crdt.spans;
    final offsets = fresh ? [for (final o in selection) o.clamp(0, text.length)] : crdt.offsetsOf(places);
    return (
      text: text,
      spans: _attributesOf(spans),
      selection: offsets,
      changed: fresh || text != localText || !_sameMarks(before, spans),
    );
  }

  static bool _sameMarks(List<MarkSpan> a, List<MarkSpan> b) {
    if (a.length != b.length) return false;
    for (var k = 0; k < a.length; k++) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  // ---- collecting what was deleted from the texts (see [TextCrdt.collect])

  /// How many deleted characters the texts still hold, and how often they were collected in all (to see that it happens).
  int get deletedInTexts => _texts.values.fold(0, (n, c) => n + c.deletedCount);
  int get textCollections => _texts.values.fold(0, (n, c) => n + c.epoch);

  /// What a guest tells the host, now and then: for each text with enough deleted to collect and nothing of its own unsent, where it is.
  Map<String, int> reportTexts() => {
        for (final e in _texts.entries)
          if (e.value.report() case final h?) e.key: h, // ignore: use_null_aware_elements
      };

  /// The host collects what was deleted from each text that every guest in [reports] (what each said last, see [reportTexts]) said it
  /// is where the host is. The keys of the texts that were collected: they go to the others with the next [localChanges], whole.
  List<String> collectTexts(List<Map<String, int>> reports) => [
        for (final e in _texts.entries)
          if (e.value.collect([for (final r in reports) r[e.key]])) e.key,
      ];

  /// What a guest said of its texts ([reportTexts]), if it is what a guest sends.
  static Map<String, int>? reportFrom(Object? json) {
    if (json is! Map || json.length > 100000) return null;
    final out = <String, int>{};
    for (final e in json.entries) {
      if (e.key is! String || e.value is! int) return null;
      out[e.key as String] = e.value as int;
    }
    return out;
  }

  // ---- devices of an older version (which do not merge texts: see [mergesTexts])

  /// Whether [json] (a change as it is sent) is a whole text from a device that does not merge texts.
  static bool isWholeText(Object? json) {
    if (json is! Map || json['x'] == true) return false;
    final isText = json['k'] == ElementKind.box.name || (json['k'] == ElementKind.note.name && json['i'] == 'doc');
    final d = json['d'];
    return isText && d is Map && d['tc'] == null;
  }

  /// [ops] (changes as they are sent) as a device that does not merge texts needs them: with the whole of each text, as it is here, and
  /// without what it does not know. (Without the text it would take a box for an empty one.)
  ///
  /// [to]: the devices it goes to (what they send later is made from these texts, see [_translate]).
  List<Object?> withWholeTexts(List<Object?> ops, {Iterable<String> to = const []}) => [for (final o in ops) _withWholeText(o, to)];

  Object? _withWholeText(Object? json, Iterable<String> to) {
    if (json is! Map || json['x'] == true) return json;
    final d = json['d'];
    if (d is! Map || d['tc'] == null) return json;
    final kind = json['k'], id = json['i'];
    final key = kind == ElementKind.box.name && id is String
        ? _key(ElementKind.box, id)
        : (kind == ElementKind.note.name && id == 'doc' ? _docKey : null);
    final crdt = key == null ? null : _texts[key];
    final out = Map<String, Object?>.of(d.cast<String, Object?>())
      ..remove('tc')
      ..remove('gv');
    if (crdt != null) {
      out['text'] = crdt.text;
      out['spans'] = _spans(_attributesOf(crdt.spans));
      for (final site in to) {
        _rememberCurrent(site, key!);
      }
    }
    // (an app that keeps only the later of two versions would drop this one for a newer-looking whole text of its own: the version is
    // made new here, which is later than everything this device has seen)
    return {...json, 'v': _tick().toJson(), 'd': out};
  }

  /// The texts whose next whole text comes from a device that does not share their history (see [startOver]).
  final Set<String> _unrelated = {};

  /// The device the changes now being applied came from (the host sets it): a whole text is made from the one that device was last
  /// given, which is not necessarily that of the device that last changed the element (see [_translate]).
  String? sender;

  /// The texts here and the ones that come next share no history: the host app was started again from the saved note, and made its
  /// texts anew. The next whole text of each is taken by comparing the texts (see [TextCrdt.adoptUnrelated]), not by the names of the
  /// characters, which would put both in, one after the other.
  void startOver() {
    _unrelated
      ..clear()
      ..addAll(_texts.keys);
  }

  /// Where things that should not happen, but can (a device that was away a long time), are told.
  static void Function(String message)? debugLog;

  static Version? _versionOf(Object? json) {
    try {
      return json == null ? null : Version.fromJson(json);
    } on Object {
      return null;
    }
  }

  /// A change to a box or to the document that has its characters: each part of it (the characters with their formatting, and for a box
  /// each part of where it is and how it looks) is taken in by itself, whether the change as a whole is older or newer than what is
  /// known. Null when the box is not here to change (the generic way to apply it is for that).
  bool? _applyParts(NoteData note, CollabOp op, _Known known, NoteFieldSink onNoteField) {
    final key = _key(op.kind, op.id);
    final d = op.data;
    var changed = false;
    if (op.kind == ElementKind.box) {
      final b = _findBox(note, op.id);
      if (b == null) return null;
      final now = _boxParts(b, _pageOf(note, b));
      final remote = _partVersions(d['gv'], op.version);
      final sig = Map.of(known.partSig), ver = Map.of(known.partVer);
      for (final part in now.keys) {
        if (now[part] != known.partSig[part]) {
          known.dirty = true; // changed here and not sent yet: it goes out at the next look, and is later than this
          continue;
        }
        final v = remote[part]!;
        if (v > (known.partVer[part] ?? const Version(0, ''))) {
          _putPart(note, b, part, d);
          ver[part] = v;
          changed = true;
        }
      }
      final after = _boxParts(b, _pageOf(note, b));
      for (final part in after.keys) {
        if (now[part] == known.partSig[part]) sig[part] = after[part]!;
      }
      known
        ..partSig = sig
        ..partVer = ver;
      final sel = b.controller.selection;
      final selection = sel.isValid ? [sel.baseOffset, sel.extentOffset] : const <int>[];
      final r = d['tc'] is Map ? _merge(key, d, b.text, b.attributes, selection, fresh: false) : _translate(key, d, sender ?? op.version.site, b.text, b.attributes, selection);
      if (r.changed) {
        _putBoxText(b, r.text, r.spans, r.selection);
        changed = true;
      }
      known.fingerprint = _boxPrint(b, _pageOf(note, b));
    } else {
      final shadow = NoteData(id: '');
      _copyNoteFieldsTo(note, shadow);
      final r = d['tc'] is Map
          ? _merge(key, d, note.documentText, note.documentSpans, const [], fresh: false)
          : _translate(key, d, sender ?? op.version.site, note.documentText, note.documentSpans, const []);
      if (r.changed) {
        onNoteField('doc', {'text': r.text, 'spans': _spans(r.spans), '_map': _mapper(note.documentText, r.text)});
        changed = true;
      }
      shadow.documentText = r.text;
      shadow.documentSpans = r.spans;
      known.fingerprint = _notePrint(shadow, 'doc');
    }
    if (op.version > known.version) known.version = op.version;
    return changed;
  }

  /// The texts that each device which does not merge was given or gave, last (by `site|key`, the latest last): what it changed in a text
  /// it sends is found against the one it started from (see [_translate]).
  final Map<String, List<({String text, List<MarkSpan> spans, List<CharId> ids})>> _bases = {};

  void _rememberBase(String site, String key, String text, List<MarkSpan> spans, List<CharId> ids) {
    final list = _bases.putIfAbsent('$site|$key', () => []);
    if (list.isNotEmpty && list.last.text == text && _sameMarks(list.last.spans, spans)) list.removeLast();
    list.add((text: text, spans: spans, ids: ids));
    if (list.length > 4) list.removeAt(0);
  }

  void _rememberCurrent(String site, String key) {
    final crdt = _texts[key];
    if (crdt == null) return;
    _rememberBase(site, key, crdt.text, crdt.spans, crdt.charactersAt([for (var k = 0; k < crdt.length; k++) k]));
  }

  /// The host gave [site] (a device that does not merge texts) all of the texts as they are: what it sends later is made from them.
  void rememberWholeTexts(String site) {
    for (final key in _texts.keys) {
      _rememberCurrent(site, key);
    }
  }

  /// The host passed [ops] (whole texts from [from], a device that does not merge) as they are to [to] (others like it): they have those
  /// texts now.
  void passBases(String from, Iterable<String> to, List<Object?> ops) {
    for (final o in ops) {
      if (!isWholeText(o)) continue;
      final m = o as Map;
      final key = m['k'] == ElementKind.box.name ? _key(ElementKind.box, m['i'] as String) : _docKey;
      final last = _bases['$from|$key']?.lastOrNull;
      if (last == null) continue;
      for (final site in to) {
        _rememberBase(site, key, last.text, last.spans, last.ids);
      }
    }
  }

  /// A whole text ([d]) from [from], a device that does not merge texts, on the device every change passes through: what it changed in
  /// the text it started from (the one of those it was given or gave last that is nearest to it) is changed here too, where those
  /// characters are now, as a change of the person here; what others wrote meanwhile stays. Its formatting replaces the formatting, if
  /// it changed it. Without a text it started from (none known), its text replaces the one here.
  ({String text, List<TextSpanAttribute> spans, List<int> selection, bool changed}) _translate(
    String key,
    Map<String, Object?> d,
    String from,
    String localText,
    List<TextSpanAttribute> localSpans,
    List<int> selection,
  ) {
    final crdt = _synced(key, localText, localSpans);
    final before = crdt.spans, beforeText = crdt.text;
    final places = crdt.placesAt([for (final o in selection) o.clamp(0, crdt.length)]);
    final text = d['text'] as String? ?? '';
    final marks = _marksOf(_spansFrom(d['spans']));
    final unknown = [for (final s in crdt.spans) if (!_knownKinds.contains(s.type)) s];
    final bases = _bases['$from|$key'] ?? const [];
    List<CharId> ids;
    if (bases.isEmpty) {
      crdt
        ..setText(text)
        ..setSpans([...marks, ...unknown]);
      ids = crdt.charactersAt([for (var k = 0; k < crdt.length; k++) k]);
    } else {
      var best = bases.last;
      var cost = -1;
      for (final b in bases.reversed) {
        var c = 0;
        for (final e in diffText(b.text, text)) {
          c += e.removed + e.inserted.length;
        }
        if (cost < 0 || c < cost) {
          best = b;
          cost = c;
        }
      }
      ids = crdt.applyWhole(best.text, best.ids, text);
      if (!_sameMarks(marks, best.spans)) crdt.setSpans([...crdt.spansOn(ids, marks), ...unknown]);
    }
    _rememberBase(from, key, text, marks, ids);
    final now = crdt.text, spans = crdt.spans;
    return (
      text: now,
      spans: _attributesOf(spans),
      selection: crdt.offsetsOf(places),
      changed: now != localText || now != beforeText || !_sameMarks(before, spans),
    );
  }

  /// A whole text came, from a device that does not merge texts: on the device every change passes through ([translatesWholeTexts]) it
  /// is taken in as a change of the person here (and goes to the others as one); elsewhere everybody starts again from it.
  void _wholeText(String key, String text, List<TextSpanAttribute> spans, {required bool fresh}) {
    if (translatesWholeTexts && !fresh && _texts.containsKey(key)) {
      _synced(key, text, spans);
    } else if (translatesWholeTexts) {
      _texts.remove(key);
      _synced(key, text, spans); // (all of it new: it goes out as the text of a device that has none of it)
    } else {
      _texts[key] = TextCrdt.shared(site, text, _marksOf(spans));
    }
  }

  /// Where a place in [oldText] is in [newText] (what a screen that keeps a cursor in the document asks): the text between them differs
  /// by what others wrote, and the place moves with it.
  static int Function(int) _mapper(String oldText, String newText) {
    final edits = diffText(oldText, newText);
    return (o) {
      var shift = 0;
      for (final e in edits) {
        if (o <= e.start) break;
        if (o >= e.start + e.removed) {
          shift += e.inserted.length - e.removed;
        } else {
          return e.start + shift + e.inserted.length;
        }
      }
      return (o + shift).clamp(0, newText.length);
    };
  }

  static int _pageOf(NoteData n, TextBoxWidgetModel b) {
    for (final e in n.textBoxes.entries) {
      if (e.value.contains(b)) return e.key;
    }
    return 0;
  }

  static void _putBoxText(TextBoxWidgetModel b, String text, List<TextSpanAttribute> spans, List<int> selection) {
    final c = b.controller;
    if (c.text != text) {
      final TextSelection sel;
      if (selection.length == 2) {
        sel = TextSelection(baseOffset: selection[0].clamp(0, text.length), extentOffset: selection[1].clamp(0, text.length));
      } else {
        sel = const TextSelection.collapsed(offset: -1);
      }
      c.value = TextEditingValue(text: text, selection: sel);
    }
    c.attributes
      ..clear()
      ..addAll(spans);
  }

  bool _applying = false;

  /// Takes what the person here changed in the texts of [note] (its boxes and its document) into them now, without sending anything.
  ///
  /// Call it at every change of a text, as it is made: one change at a time is one edit at exactly the place it was made. Changes that
  /// are only looked for later ([localChanges]) are found by comparing the texts, and several of them at once can be told apart only
  /// by guessing - in a text with many `[`, `:` and spaces, a guess can put a word of one person into the middle of another's.
  void capture(NoteData note) {
    if (_applying || !mergesTexts) return; // (a change that is being taken in sets the texts, and is no change of the person here)
    note.textBoxes.forEach((page, list) {
      for (final b in list) {
        final key = _key(ElementKind.box, b.id);
        final known = _known[key];
        if (known != null && known.deleted) continue; // (comes back as a new text: see [localChanges])
        _synced(key, b.text, b.attributes);
      }
    });
    _synced(_docKey, note.documentText, note.documentSpans);
  }

  // ---- finding what changed here

  /// The changes the person here made to [note] since the last call: new elements, changed ones,
  /// and deleted ones. [readImage] reads a picture's bytes (sent along the first time).
  List<CollabOp> localChanges(NoteData note, {Uint8List? Function(String path)? readImage}) {
    final ops = <CollabOp>[];
    final seen = <String>{};

    void check(ElementKind kind, String id, int fingerprint, Map<String, Object?> Function() data, {TextCrdt? crdt, Map<String, int>? parts}) {
      final key = _key(kind, id);
      seen.add(key);
      final known = _known[key];
      if (known != null && !known.deleted && known.fingerprint == fingerprint && !known.dirty && !(crdt?.hasChanges ?? false)) return;
      final v = _tick();
      final d = data();
      final generation = known == null ? 0 : (known.deleted ? known.generation + 1 : known.generation);
      final fresh = known == null || known.deleted;
      if (crdt != null) {
        // (a text that is sent for the first time, or comes back after being deleted, goes whole: the others have none of it)
        d.addAll(_textPart(crdt, whole: fresh));
        if (!wholeTexts) {
          d
            ..remove('text')
            ..remove('spans');
        }
      }
      // each part of a box has the version of the change that last made it different, not of this one
      final partVer = <String, Version>{
        if (parts != null)
          for (final e in parts.entries) e.key: !fresh && known.partSig[e.key] == e.value ? known.partVer[e.key] ?? v : v,
      };
      if (parts != null) d['gv'] = {for (final e in partVer.entries) e.key: e.value.toJson()};
      if (kind == ElementKind.image && (known == null || known.deleted)) {
        // the picture itself goes along the first time
        final m = _findImage(note, id)!;
        final bytes = (readImage ?? _readFile)(m.path);
        if (bytes != null) {
          d['bytes'] = base64Encode(bytes);
          d['ext'] = _extension(m.path);
        }
      }
      _known[key] = _Known(v, false, fingerprint, generation)
        ..partSig = parts ?? const {}
        ..partVer = partVer;
      ops.add(CollabOp(kind, id, v, generation: generation, data: d));
    }

    note.strokes.forEach((page, list) {
      for (final s in list) {
        if (holdBack.contains(s.id)) {
          seen.add(_key(ElementKind.stroke, s.id)); // (neither new nor gone yet)
          continue;
        }
        if (s.points.length >= 2) check(ElementKind.stroke, s.id, _strokePrint(s, page), () => _strokeData(s, page));
      }
    });
    note.textBoxes.forEach((page, list) {
      for (final b in list) {
        final key = _key(ElementKind.box, b.id);
        if (_known[key]?.deleted ?? false) _texts.remove(key); // (it comes back as a new one)
        if (!mergesTexts) {
          check(ElementKind.box, b.id, _boxPrint(b, page), () => _boxData(b, page)); // (as an app from before texts were merged)
          continue;
        }
        check(ElementKind.box, b.id, _boxPrint(b, page), () => _boxData(b, page), crdt: _synced(key, b.text, b.attributes), parts: _boxParts(b, page));
      }
    });
    note.images.forEach((page, list) {
      for (final m in list) {
        check(ElementKind.image, m.id, _imagePrint(m, page), () => _imageData(m, page));
      }
    });
    note.highlights.forEach((page, list) {
      for (final h in list) {
        check(ElementKind.mark, h.id, _markPrint(h, page), () => _markData(h, page));
      }
    });
    for (final f in noteFields) {
      if (f == 'doc' && mergesTexts) {
        check(ElementKind.note, f, _notePrint(note, f), () => _noteData(note, f), crdt: _synced(_docKey, note.documentText, note.documentSpans));
      } else {
        check(ElementKind.note, f, _notePrint(note, f), () => _noteData(note, f));
      }
    }

    // what was there and is not now
    for (final e in _known.entries.toList()) {
      if (e.value.deleted || seen.contains(e.key)) continue;
      final colon = e.key.indexOf(':');
      final kind = ElementKind.values.firstWhere((k) => k.name == e.key.substring(0, colon));
      if (kind == ElementKind.note) continue;
      final v = _tick();
      _texts.remove(e.key);
      e.value
        ..version = v
        ..deleted = true;
      ops.add(CollabOp(kind, e.key.substring(colon + 1), v, deleted: true, generation: e.value.generation));
    }
    return ops;
  }

  static Uint8List? _readFile(String path) {
    try {
      return File(path).readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    final e = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    return e.isEmpty || e.length > 5 ? 'png' : e;
  }

  /// All of the note as changes, at the versions they have: what a device that joins is given. Call
  /// [localChanges] first, so that what was changed just now is in it.
  ///
  /// With [includeDeleted] the elements that were deleted are in it too, as deletions: for taking
  /// a note up to date that may still have them.
  ///
  /// [wholeTexts]: the texts also go as plain text, for a device that does not merge them (see [Replica.wholeTexts]).
  List<CollabOp> state(NoteData note, {Uint8List? Function(String path)? readImage, bool includeDeleted = false, bool? wholeTexts}) {
    final ops = <CollabOp>[];
    final plain = wholeTexts ?? this.wholeTexts;
    void add(ElementKind kind, String id, Map<String, Object?> Function() data, {List<TextSpanAttribute>? spans}) {
      final key = _key(kind, id);
      final known = _known[key];
      if (known == null || known.deleted) return;
      final d = data();
      final crdt = spans == null || !mergesTexts ? null : _texts[key];
      if (crdt != null) {
        d.addAll(_textPart(crdt, whole: true, consume: false));
        if (!plain) {
          d
            ..remove('text')
            ..remove('spans');
        }
      }
      if (kind == ElementKind.box && mergesTexts) d['gv'] = {for (final e in known.partVer.entries) e.key: e.value.toJson()};
      ops.add(CollabOp(kind, id, known.version, generation: known.generation, data: d));
    }

    note.strokes.forEach((page, list) {
      for (final s in list) {
        if (s.points.length >= 2) add(ElementKind.stroke, s.id, () => _strokeData(s, page));
      }
    });
    note.textBoxes.forEach((page, list) {
      for (final b in list) {
        add(ElementKind.box, b.id, () => _boxData(b, page), spans: b.attributes);
      }
    });
    note.images.forEach((page, list) {
      for (final m in list) {
        add(ElementKind.image, m.id, () {
          final d = _imageData(m, page);
          final bytes = (readImage ?? _readFile)(m.path);
          if (bytes != null) {
            d['bytes'] = base64Encode(bytes);
            d['ext'] = _extension(m.path);
          }
          return d;
        });
      }
    });
    note.highlights.forEach((page, list) {
      for (final h in list) {
        add(ElementKind.mark, h.id, () => _markData(h, page));
      }
    });
    for (final f in noteFields) {
      add(ElementKind.note, f, () => _noteData(note, f), spans: f == 'doc' ? note.documentSpans : null);
    }
    if (includeDeleted) {
      for (final e in _known.entries) {
        if (!e.value.deleted) continue;
        final colon = e.key.indexOf(':');
        ops.add(CollabOp(ElementKind.values.firstWhere((k) => k.name == e.key.substring(0, colon)), e.key.substring(colon + 1), e.value.version,
            deleted: true, generation: e.value.generation));
      }
    }
    return ops;
  }

  // ---- taking in what others changed

  static DrawingStroke? _findStroke(NoteData n, String id) {
    for (final list in n.strokes.values) {
      for (final s in list) {
        if (s.id == id) return s;
      }
    }
    return null;
  }

  static TextBoxWidgetModel? _findBox(NoteData n, String id) {
    for (final list in n.textBoxes.values) {
      for (final b in list) {
        if (b.id == id) return b;
      }
    }
    return null;
  }

  static ImageItem? _findImage(NoteData n, String id) {
    for (final list in n.images.values) {
      for (final m in list) {
        if (m.id == id) return m;
      }
    }
    return null;
  }

  static PdfHighlight? _findMark(NoteData n, String id) {
    for (final list in n.highlights.values) {
      for (final h in list) {
        if (h.id == id) return h;
      }
    }
    return null;
  }

  /// Takes in the designed brush that came with a line, if it is the one the line names (the id is made of the numbers, so a
  /// line cannot give another brush the id of one that is there) and this device does not have it yet.
  static void _learnBrush(String id, Object? description) {
    if (description == null || !id.startsWith(customBrushPrefix) || CustomBrushes.of(id) != null) return;
    try {
      final desc = BrushDesc.fromCompactJson(description);
      if (desc.id == id) CustomBrushes.learn(desc);
    } on BrushDescException {
      // (not a brush this app can read: the line is drawn as the pen)
    }
  }

  static int _page(Map<String, Object?> d) => (d['p'] as num?)?.toInt() ?? 0;
  static double _num(Object? v, double fallback) => v is num ? v.toDouble() : fallback;

  /// Takes in a change made on another device. Does nothing, and says false, if this device
  /// has the element at that version or a later one already.
  bool apply(
    NoteData note,
    CollabOp op, {
    required BoxMaker makeBox,
    required ImageSaver saveImage,
    required NoteFieldSink onNoteField,
  }) {
    final was = _applying;
    _applying = true;
    try {
      return _apply(note, op, makeBox: makeBox, saveImage: saveImage, onNoteField: onNoteField);
    } finally {
      _applying = was;
    }
  }

  bool _apply(
    NoteData note,
    CollabOp op, {
    required BoxMaker makeBox,
    required ImageSaver saveImage,
    required NoteFieldSink onNoteField,
  }) {
    if (op.version.clock > _clock) _clock = op.version.clock;
    final key = _key(op.kind, op.id);
    final known = _known[key];
    final isText = op.kind == ElementKind.box || (op.kind == ElementKind.note && op.id == 'doc');
    final merged = mergesTexts && op.data['tc'] is Map;
    // (whole texts of a device that does not merge, on the device every change passes through: what it changed is taken in, whatever
    // the version, see [_translate])
    final translated = mergesTexts && translatesWholeTexts && !merged && _texts.containsKey(key);
    if (known != null && isText && !op.deleted && !known.deleted && op.generation == known.generation && (merged || translated)) {
      // (the parts of a text are neither older nor newer than others: see [_applyParts])
      final done = _applyParts(note, op, known, onNoteField);
      if (done != null) return done;
    }
    if (known != null && !known.replacedBy(op)) return false;

    final d = op.data;
    // a text that comes back after being deleted starts again: the characters of the one that was are not those of this
    final fresh = known == null || known.deleted || op.generation > known.generation;
    int fingerprint = 0;
    switch (op.kind) {
      case ElementKind.stroke:
        var s = _findStroke(note, op.id);
        if (op.deleted) {
          for (final list in note.strokes.values) {
            list.removeWhere((x) => x.id == op.id);
          }
          break;
        }
        final page = _page(d);
        final points = decodePoints(base64Decode(d['pts'] as String));
        if (s == null) {
          s = DrawingStroke(id: op.id, color: Color((d['c'] as num).toInt()), width: _num(d['w'], 3), points: points, author: d['a'] as String?);
          note.strokes.putIfAbsent(page, () => []).add(s);
        } else {
          s.color = Color((d['c'] as num).toInt());
          s.width = _num(d['w'], s.width);
          s.points
            ..clear()
            ..addAll(points);
          if (!(note.strokes[page]?.contains(s) ?? false)) {
            for (final list in note.strokes.values) {
              list.remove(s);
            }
            note.strokes.putIfAbsent(page, () => []).add(s);
          }
        }
        s.dash = StrokeDash.byIndex((d['d'] as num?)?.toInt());
        s.fill = d['f'] == null ? null : Color((d['f'] as num).toInt());
        final pr = d['pr'] == null ? null : base64Decode(d['pr'] as String);
        s.pressures = pr != null && pr.length == s.points.length ? List.of(pr) : null;
        s.brush = (d['b'] as String?) ?? penBrushId;
        _learnBrush(s.brush, d['bd']);
        s.layer = (d['ly'] as String?) ?? baseLayerId;
        s.link = StrokeLink.fromJson(d['ln']);
        s.group = (d['gr'] as String?) ?? noGroup;
        s.curve = CurvedPath.decode(d['cv'] as String?);
        s.gradient = FillGradient.decode(d['gd'] as String?);
        s.label = StrokeLabel.decode(d['lb'] as String?);
        fingerprint = _strokePrint(s, page);
      case ElementKind.box:
        var b = _findBox(note, op.id);
        if (op.deleted) {
          for (final list in note.textBoxes.values) {
            list.removeWhere((x) => x.id == op.id);
          }
          break;
        }
        final page = _page(d);
        if (b == null) {
          b = makeBox(op.id)..author = d['a'] as String?; // (who made it stays what it was when it is changed)
          note.textBoxes.putIfAbsent(page, () => []).add(b);
        } else if (!(note.textBoxes[page]?.contains(b) ?? false)) {
          for (final list in note.textBoxes.values) {
            list.remove(b);
          }
          note.textBoxes.putIfAbsent(page, () => []).add(b);
        }
        for (final part in const ['at', 'size', 'fs', 'style', 'ly', 'gr']) {
          _putPart(note, b, part, d);
        }
        if (merged) {
          final sel = b.controller.selection;
          final r = _merge(key, d, b.text, b.attributes, sel.isValid ? [sel.baseOffset, sel.extentOffset] : const [], fresh: fresh);
          _putBoxText(b, r.text, r.spans, r.selection);
        } else {
          // from a device that does not merge texts (an older version of the app, or a copy that was changed while its owner was away):
          // its text replaces ours
          final text = d['text'] as String? ?? '';
          final spans = _spansFrom(d['spans']);
          if (b.controller.text != text) {
            final at = b.controller.selection;
            b.controller.text = text;
            if (at.isValid && at.end <= text.length) b.controller.selection = at; // the cursor stays where it was
          }
          b.controller.attributes
            ..clear()
            ..addAll(spans);
          _wholeText(key, text, spans, fresh: fresh);
        }
        fingerprint = _boxPrint(b, page);
      case ElementKind.image:
        var m = _findImage(note, op.id);
        if (op.deleted) {
          for (final list in note.images.values) {
            list.removeWhere((x) => x.id == op.id);
          }
          break;
        }
        final page = _page(d);
        if (m == null) {
          final bytes = d['bytes'] as String?;
          if (bytes == null) return false; // a move of a picture that never came: nothing to move
          if (bytes.length > maxPeerImageBase64) return false; // (a picture of a peer is not let to take all the memory)
          final path = saveImage(op.id, base64Decode(bytes), d['ext'] as String? ?? 'png');
          m = ImageItem(id: op.id, path: path, position: Offset.zero, size: Size.zero, author: d['a'] as String?);
          note.images.putIfAbsent(page, () => []).add(m);
        } else if (!(note.images[page]?.contains(m) ?? false)) {
          for (final list in note.images.values) {
            list.remove(m);
          }
          note.images.putIfAbsent(page, () => []).add(m);
        }
        m.position = Offset(_num(d['x'], 0), _num(d['y'], 0));
        m.size = Size(_num(d['w'], 100), _num(d['h'], 100));
        m.layer = (d['ly'] as String?) ?? baseLayerId;
        m.group = (d['gr'] as String?) ?? noGroup;
        fingerprint = _imagePrint(m, page);
      case ElementKind.mark:
        if (op.deleted) {
          for (final list in note.highlights.values) {
            list.removeWhere((x) => x.id == op.id);
          }
          break;
        }
        if (_findMark(note, op.id) == null) {
          final page = _page(d);
          final h = PdfHighlight(
            id: op.id,
            rect: Rect.fromLTRB(_num(d['l'], 0), _num(d['t'], 0), _num(d['r'], 0), _num(d['b'], 0)),
            color: Color((d['c'] as num).toInt()),
            commentBox: d['cb'] as String?,
            author: d['a'] as String?,
          );
          note.highlights.putIfAbsent(page, () => []).add(h);
          fingerprint = _markPrint(h, page);
        } else {
          fingerprint = known?.fingerprint ?? 0; // a mark never changes once made
        }
      case ElementKind.note:
        var field = d;
        if (op.id == 'doc') {
          if (merged) {
            final r = _merge(key, d, note.documentText, note.documentSpans, const [], fresh: fresh);
            field = {...d, 'text': r.text, 'spans': _spans(r.spans), '_map': _mapper(note.documentText, r.text)};
          } else {
            final text = d['text'] as String? ?? '';
            _wholeText(key, text, _spansFrom(d['spans']), fresh: fresh);
            field = {...d, 'text': text, '_map': _mapper(note.documentText, text)};
          }
        }
        onNoteField(op.id, field);
        // what the field is as it now is, so that the next look here does not send it back
        final shadow = NoteData(id: '');
        _copyNoteFieldsTo(note, shadow);
        applyNoteField(shadow, op.id, field);
        fingerprint = _notePrint(shadow, op.id);
    }
    if (op.deleted) _texts.remove(key);
    final box = op.kind == ElementKind.box && !op.deleted ? _findBox(note, op.id) : null;
    _known[key] = _Known(op.version, op.deleted, fingerprint, op.generation)
      ..partSig = box == null ? const {} : _boxParts(box, _pageOf(note, box))
      ..partVer = box == null ? const {} : _partVersions(d['gv'], op.version);
    return true;
  }

  static void _copyNoteFieldsTo(NoteData from, NoteData to) {
    to
      ..title = from.title
      ..background = from.background
      ..pageFormat = from.pageFormat
      ..landscape = from.landscape
      ..nativePages = Set.of(from.nativePages)
      ..marginLeft = from.marginLeft
      ..marginRight = from.marginRight
      ..marginTop = from.marginTop
      ..marginBottom = from.marginBottom
      ..layers = from.layers
      ..documentText = from.documentText
      ..documentSpans = from.documentSpans;
  }
}
