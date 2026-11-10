import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

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

  /// [clock] to carry on from another replica of the same device.
  Replica(this.site, {int clock = 0}) : _clock = clock;

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
        'text': b.controller.text,
        'spans': _spans(b.controller.attributes),
        if (!b.style.isDefault) 'style': b.style.toJson(),
        if (b.author != null) 'a': b.author,
        if (b.layer != baseLayerId) 'ly': b.layer,
        if (b.group != noGroup) 'gr': b.group,
      };
  static int _boxPrint(TextBoxWidgetModel b, int page) =>
      Object.hash(page, b.position, b.size, b.fontSize, b.style, b.controller.text, _hashSpans(b.controller.attributes), b.layer, b.group);

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

  // ---- finding what changed here

  /// The changes the person here made to [note] since the last call: new elements, changed ones,
  /// and deleted ones. [readImage] reads a picture's bytes (sent along the first time).
  List<CollabOp> localChanges(NoteData note, {Uint8List? Function(String path)? readImage}) {
    final ops = <CollabOp>[];
    final seen = <String>{};

    void check(ElementKind kind, String id, int fingerprint, Map<String, Object?> Function() data) {
      final key = _key(kind, id);
      seen.add(key);
      final known = _known[key];
      if (known != null && !known.deleted && known.fingerprint == fingerprint) return;
      final v = _tick();
      final d = data();
      final generation = known == null ? 0 : (known.deleted ? known.generation + 1 : known.generation);
      if (kind == ElementKind.image && (known == null || known.deleted)) {
        // the picture itself goes along the first time
        final m = _findImage(note, id)!;
        final bytes = (readImage ?? _readFile)(m.path);
        if (bytes != null) {
          d['bytes'] = base64Encode(bytes);
          d['ext'] = _extension(m.path);
        }
      }
      _known[key] = _Known(v, false, fingerprint, generation);
      ops.add(CollabOp(kind, id, v, generation: generation, data: d));
    }

    note.strokes.forEach((page, list) {
      for (final s in list) {
        if (s.points.length >= 2) check(ElementKind.stroke, s.id, _strokePrint(s, page), () => _strokeData(s, page));
      }
    });
    note.textBoxes.forEach((page, list) {
      for (final b in list) {
        check(ElementKind.box, b.id, _boxPrint(b, page), () => _boxData(b, page));
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
      check(ElementKind.note, f, _notePrint(note, f), () => _noteData(note, f));
    }

    // what was there and is not now
    for (final e in _known.entries.toList()) {
      if (e.value.deleted || seen.contains(e.key)) continue;
      final colon = e.key.indexOf(':');
      final kind = ElementKind.values.firstWhere((k) => k.name == e.key.substring(0, colon));
      if (kind == ElementKind.note) continue;
      final v = _tick();
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
  List<CollabOp> state(NoteData note, {Uint8List? Function(String path)? readImage, bool includeDeleted = false}) {
    final ops = <CollabOp>[];
    void add(ElementKind kind, String id, Map<String, Object?> Function() data) {
      final known = _known[_key(kind, id)];
      if (known == null || known.deleted) return;
      ops.add(CollabOp(kind, id, known.version, generation: known.generation, data: data()));
    }

    note.strokes.forEach((page, list) {
      for (final s in list) {
        if (s.points.length >= 2) add(ElementKind.stroke, s.id, () => _strokeData(s, page));
      }
    });
    note.textBoxes.forEach((page, list) {
      for (final b in list) {
        add(ElementKind.box, b.id, () => _boxData(b, page));
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
      add(ElementKind.note, f, () => _noteData(note, f));
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
    if (op.version.clock > _clock) _clock = op.version.clock;
    final key = _key(op.kind, op.id);
    final known = _known[key];
    if (known != null && !known.replacedBy(op)) return false;

    final d = op.data;
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
        b.position = Offset(_num(d['x'], 0), _num(d['y'], 0));
        b.size = Size(_num(d['w'], 260), _num(d['h'], 0));
        b.fontSize = _num(d['fs'], 16);
        b.layer = (d['ly'] as String?) ?? baseLayerId;
        b.group = (d['gr'] as String?) ?? noGroup;
        b.style = TextBoxStyle.fromJson(d['style']);
        final text = d['text'] as String? ?? '';
        if (b.controller.text != text) {
          final at = b.controller.selection;
          b.controller.text = text;
          if (at.isValid && at.end <= text.length) b.controller.selection = at; // the cursor stays where it was
        }
        b.controller.attributes
          ..clear()
          ..addAll(_spansFrom(d['spans']));
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
        onNoteField(op.id, d);
        // what the field is as it now is, so that the next look here does not send it back
        final shadow = NoteData(id: '');
        _copyNoteFieldsTo(note, shadow);
        applyNoteField(shadow, op.id, d);
        fingerprint = _notePrint(shadow, op.id);
    }
    _known[key] = _Known(op.version, op.deleted, fingerprint, op.generation);
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
