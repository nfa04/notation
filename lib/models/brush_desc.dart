import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'brush.dart';

/// The extension of a file that holds one designed brush: `.strokedesc`, JSON (see [BrushDesc.toJson]).
const strokeDescExtension = 'strokedesc';

/// The ids of designed brushes start with this; the rest is made of the numbers that describe the brush (see [BrushDesc.id]).
const customBrushPrefix = 'custom:';

/// The version of the `.strokedesc` format this app writes. A reader must ignore fields it does not know; a change that breaks
/// readers raises this.
const strokeDescVersion = 1;

/// The most a `.strokedesc` file may be. (Every one that is made is a few hundred bytes.)
const strokeDescMaxBytes = 16 * 1024;

/// Why a `.strokedesc` is not one this app can use.
class BrushDescException implements Exception {
  final String message;
  const BrushDescException(this.message);

  @override
  String toString() => message;
}

/// The kinds of brush that can be designed, by the way they draw.
enum BrushKind {
  /// A line of ink: thickness that follows the pressure, pointed ends, a flat nib, rough edges ([ParamBrush]).
  ink,

  /// A wide band with the streaks and ridges of a paint roller ([RollerBrush]).
  roller,

  /// A soft spray or wash that is strongest along the middle ([SoftBrush]).
  soft,

  /// Streaks of dark grain with crumbling dust ([CharcoalBrush]).
  charcoal,

  /// The same small shape stamped again and again along the line ([StampBrush]).
  stamp,
}

/// One number a brush is described by: its name in the file, what the person sees it called, its range and what it is when nothing
/// is said. An [optional] one can be left out (then the thing it sets is off: a round tip has no nib angle).
///
/// A [sparse] one is left out of the id of a brush when it is at its standard. Every number added to a kind after the first version
/// is sparse: the id of a brush that was made before it was there is then the id it still has, and the lines drawn with it keep their
/// look. (A number that is not sparse is part of the id always; those are the numbers the kinds had to begin with.)
///
/// An [advanced] one is shown under *Advanced*. [choices], if there are any, name the whole numbers from [min] to [max] (a shape, a
/// blend); the knob then moves in whole steps.
class BrushKnob {
  final String key;
  final String label;
  final double min, max, standard;
  final bool optional, sparse, advanced;
  final List<String>? choices;

  const BrushKnob(this.key, this.label, this.min, this.max, this.standard, {this.optional = false, this.sparse = false, this.advanced = false, this.choices});

  /// The text for [value]: the name of the choice, or the number.
  String show(double value) {
    final c = choices;
    if (c != null) return c[value.round().clamp(0, c.length - 1)];
    return value.abs() >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(value.abs() >= 10 ? 1 : 2);
  }

  double clamp(double v) => choices != null ? v.round().clamp(min.round(), max.round()).toDouble() : v.clamp(min, max).toDouble();
}

/// A brush as numbers: what a `.strokedesc` file holds, and what the brush menu's designer edits. A stroke that was drawn with it
/// keeps only the [id], which is made of the numbers themselves, so a line always means the look it was drawn with: changing a
/// brush makes another id, and the lines drawn with the old one stay as they were. The name is not part of the id.
class BrushDesc {
  final BrushKind kind;
  final String name;

  /// The value of every [BrushKnob] of the kind (an optional one that is off is not there), rounded to thousandths.
  final Map<String, double> params;

  const BrushDesc._(this.kind, this.name, this.params);

  /// The most characters of a name.
  static const maxName = 40;

  /// A brush of [kind] with [params]: a number outside the range of its knob is brought into it, one that is not given is the
  /// knob's standard, and numbers the kind does not have are left out.
  factory BrushDesc(BrushKind kind, String name, [Map<String, double> params = const {}]) {
    final clean = <String, double>{};
    for (final k in knobsOf(kind)) {
      final v = params[k.key];
      if (v == null) {
        if (!k.optional) clean[k.key] = k.standard;
        continue;
      }
      if (!v.isFinite) throw BrushDescException('"${k.key}" is not a number.');
      clean[k.key] = _round(k.clamp(v));
    }
    var n = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (n.length > maxName) n = n.substring(0, maxName).trim();
    return BrushDesc._(kind, n.isEmpty ? defaultName(kind) : n, Map.unmodifiable(clean));
  }

  static double _round(double v) => (v * 1000).round() / 1000;

  /// What a brush of [kind] is called when it has no name.
  static String defaultName(BrushKind kind) => switch (kind) {
        BrushKind.ink => 'Ink brush',
        BrushKind.roller => 'Roller brush',
        BrushKind.soft => 'Soft brush',
        BrushKind.charcoal => 'Charcoal brush',
        BrushKind.stamp => 'Stamp brush',
      };

  /// The numbers of [kind], in the order the designer shows them.
  static List<BrushKnob> knobsOf(BrushKind kind) => _knobs[kind]!;

  static const _knobs = <BrushKind, List<BrushKnob>>{
    BrushKind.ink: [
      BrushKnob('width', 'Thickness', 0.2, 10, 1),
      BrushKnob('pressure', 'Pressure', 0, 1, 0),
      BrushKnob('smoothing', 'Smoothing', 0, 1, 0.5),
      BrushKnob('taper', 'Pointed ends', 0, 1, 0),
      BrushKnob('opacity', 'Opacity', 0.05, 1, 1),
      BrushKnob('jitter', 'Rough edges', 0, 1, 0),
      BrushKnob('nibAngle', 'Flat nib angle', 0, 179, 40, optional: true),
      BrushKnob('nibFlatness', 'Nib flatness', 0.05, 1, 0.15),
      BrushKnob('pressureCurve', 'Pressure curve', 0.3, 3, 1, sparse: true, advanced: true),
      BrushKnob('speedThin', 'Thinner when fast', 0, 1, 0, sparse: true, advanced: true),
      BrushKnob('startTaper', 'Pointed start', 0, 1, 0.5, optional: true, sparse: true, advanced: true),
      BrushKnob('endTaper', 'Pointed end', 0, 1, 0.5, optional: true, sparse: true, advanced: true),
      BrushKnob('waver', 'Hand wobble', 0, 1, 0, sparse: true, advanced: true),
      BrushKnob('lightness', 'Lighter and darker', 0, 1, 0, sparse: true, advanced: true),
      BrushKnob('hue', 'Colour drift', 0, 60, 0, sparse: true, advanced: true),
      _blend,
    ],
    BrushKind.roller: [
      BrushKnob('width', 'Thickness', 1, 12, 5),
      BrushKnob('coat', 'Coat', 0.1, 1, 0.5),
      BrushKnob('streaks', 'Streaks', 0, 1.5, 1),
      BrushKnob('ridge', 'Edge ridges', 0, 1, 0.35),
      BrushKnob('dryness', 'Dry lanes', 0, 0.8, 0.3),
      BrushKnob('streakLength', 'Streak length', 0.3, 3, 1, sparse: true, advanced: true),
      BrushKnob('laneWidth', 'Lane width', 0.4, 3, 1, sparse: true, advanced: true),
      BrushKnob('ridgeWidth', 'Ridge width', 0.02, 0.4, 0.14, sparse: true, advanced: true),
      _blend,
    ],
    BrushKind.soft: [
      BrushKnob('width', 'Thickness', 0.5, 12, 6),
      BrushKnob('strength', 'Strength', 0.1, 1, 1),
      BrushKnob('softness', 'Softness', 0, 1, 0.6),
      BrushKnob('speckle', 'Spray specks', 0, 10, 0),
      BrushKnob('wobble', 'Uneven edges', 0, 1, 0),
      BrushKnob('speckleSize', 'Speck size', 0.3, 3, 1, sparse: true, advanced: true),
      BrushKnob('speckleSpread', 'Speck reach', 0.3, 3, 1, sparse: true, advanced: true),
      BrushKnob('blur', 'Blur amount', 0, 2, 1, sparse: true, advanced: true),
    ],
    BrushKind.charcoal: [
      BrushKnob('width', 'Thickness', 0.5, 10, 3),
      BrushKnob('pressure', 'Pressure', 0, 1, 0.7),
      BrushKnob('taper', 'Crumbling ends', 0, 1, 0.35),
      BrushKnob('jitter', 'Rough edges', 0, 1, 0.12),
      BrushKnob('body', 'Body', 0, 0.6, 0.1),
      BrushKnob('dryness', 'Gaps in the streaks', 0, 0.8, 0.3),
      BrushKnob('dust', 'Dust', 0, 3, 1),
      BrushKnob('grainSize', 'Grain size', 0.4, 3, 1, sparse: true, advanced: true),
      BrushKnob('runLength', 'Streak length', 0.3, 3, 1, sparse: true, advanced: true),
      BrushKnob('dustSpread', 'Dust reach', 0.3, 3, 1, sparse: true, advanced: true),
      BrushKnob('dustSize', 'Dust size', 0.3, 3, 1, sparse: true, advanced: true),
    ],
    BrushKind.stamp: [
      BrushKnob('width', 'Thickness', 0.5, 12, 4, sparse: true),
      BrushKnob('spacing', 'Spacing', 0.05, 3, 0.35, sparse: true),
      BrushKnob('shape', 'Shape', 0, 4, 0, sparse: true, choices: ['Round', 'Square', 'Triangle', 'Star', 'Leaf']),
      BrushKnob('scatter', 'Scatter', 0, 2, 0, sparse: true),
      BrushKnob('sizeJitter', 'Size variation', 0, 1, 0.2, sparse: true),
      BrushKnob('opacity', 'Opacity', 0.05, 1, 1, sparse: true),
      BrushKnob('pressure', 'Pressure', 0, 1, 0.5, sparse: true, advanced: true),
      BrushKnob('squash', 'Flatness', 0.1, 1, 1, sparse: true, advanced: true),
      BrushKnob('angle', 'Angle', 0, 179, 0, sparse: true, advanced: true),
      BrushKnob('angleJitter', 'Angle variation', 0, 1, 0, sparse: true, advanced: true),
      BrushKnob('follow', 'Turns with', 0, 1, 0, sparse: true, advanced: true, choices: ['The page', 'The line']),
      BrushKnob('lightness', 'Lighter and darker', 0, 1, 0, sparse: true, advanced: true),
      BrushKnob('hue', 'Colour drift', 0, 60, 0, sparse: true, advanced: true),
      _blend,
    ],
  };

  static const _blend = BrushKnob('blend', 'Where lines cross', 0, 1, 0, sparse: true, advanced: true, choices: ['Normal', 'Darker']);

  /// The value of [key].
  double? operator [](String key) => params[key];

  double _p(String key) => params[key] ?? knobsOf(kind).firstWhere((k) => k.key == key).standard;

  /// This brush with the number [key] set to [value] (null: off, for a knob that can be off) and everything else as it is.
  BrushDesc withValue(String key, double? value) {
    final next = Map.of(params);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    return BrushDesc(kind, name, next);
  }

  BrushDesc named(String newName) => BrushDesc(kind, newName, params);

  /// The id a stroke keeps: [customBrushPrefix] and a number made of the kind and the numbers (not the name). The same design is the
  /// same id on every device and in every version of the app; the number is made with sums and remainders only, so that it comes out
  /// the same in a browser. Not a secret and not a promise against someone who sets out to make two designs with one id (the harm
  /// would be a line drawn with the wrong look).
  String get id {
    final text = StringBuffer(kind.name);
    for (final k in knobsOf(kind)) {
      final v = params[k.key];
      // (a number added after the first version is left out at its standard: see BrushKnob.sparse)
      if (v != null && !(k.sparse && !k.optional && v == k.standard)) text.write(';${k.key}=${v.toStringAsFixed(3)}');
    }
    var a = 17, b = 29;
    for (final u in text.toString().codeUnits) {
      a = (a * 131 + u) % 2147483647;
      b = (b * 257 + u + 7) % 2147483629;
    }
    String hex(int v) => v.toRadixString(16).padLeft(8, '0');
    return '$customBrushPrefix${hex(a)}${hex(b)}';
  }

  /// The brush this describes, ready for [Brushes].
  Brush build() {
    final id = this.id;
    switch (kind) {
      case BrushKind.ink:
        return ParamBrush(id, name, _inkParams(), icon: Icons.brush_outlined);
      case BrushKind.roller:
        return RollerBrush(
          id: id,
          label: name,
          params: RollerParams(
            width: _p('width'),
            coat: _p('coat'),
            streaks: _p('streaks'),
            ridge: _p('ridge'),
            dryness: _p('dryness'),
            streakLength: _p('streakLength'),
            laneWidth: _p('laneWidth'),
            ridgeWidth: _p('ridgeWidth'),
            multiply: _p('blend') >= 0.5,
          ),
        );
      case BrushKind.soft:
        return _soft(id);
      case BrushKind.charcoal:
        return CharcoalBrush(
          id,
          name,
          Icons.gradient,
          ParamBrush(id, name, BrushParams(width: _p('width'), pressure: _p('pressure'), smoothing: 0.2, jitter: _p('jitter'), opacity: math.max(_p('body'), 0.01), taper: _p('taper'))),
          dryness: _p('dryness'),
          dust: _p('dust'),
          grainSize: _p('grainSize'),
          runLength: _p('runLength'),
          dustSpread: _p('dustSpread'),
          dustSize: _p('dustSize'),
        );
      case BrushKind.stamp:
        return StampBrush(
          id,
          name,
          widthScale: _p('width'),
          params: StampParams(
            spacing: _p('spacing'),
            scatter: _p('scatter'),
            sizeJitter: _p('sizeJitter'),
            pressure: _p('pressure'),
            shape: StampShape.values[_p('shape').round().clamp(0, StampShape.values.length - 1)],
            squash: _p('squash'),
            angle: _p('angle'),
            angleJitter: _p('angleJitter'),
            follow: _p('follow') >= 0.5,
            opacity: _p('opacity'),
            lightness: _p('lightness'),
            hue: _p('hue'),
            multiply: _p('blend') >= 0.5,
          ),
        );
    }
  }

  BrushParams _inkParams() => BrushParams(
        width: _p('width'),
        pressure: _p('pressure'),
        smoothing: _p('smoothing'),
        taper: _p('taper'),
        opacity: _p('opacity'),
        jitter: _p('jitter'),
        nibAngle: params['nibAngle'],
        nibFlatness: _p('nibFlatness'),
        pressureCurve: _p('pressureCurve'),
        speedThin: _p('speedThin'),
        startTaper: params['startTaper'],
        endTaper: params['endTaper'],
        waver: _p('waver'),
        lightness: _p('lightness'),
        hue: _p('hue'),
        multiply: _p('blend') >= 0.5,
      );

  /// A soft brush: the same line drawn in layers, each narrower, whose opacities add up to a bell curve ([softness] 0 is flat with
  /// a hard edge, 1 is a sharp peak that fades to nothing); on the screen the layers are blurred as well, in proportion.
  SoftBrush _soft(String id) {
    final strength = _p('strength'), softness = _p('softness');
    // (the width of the bell: 6 is flat over the whole line, 0.3 a sharp peak; at 0.6 the edge has about a tenth of the middle, as a spray has)
    final sigma = 0.3 + 5.7 * math.pow(1 - softness, 3);
    double profile(double r) => math.exp(-(r * r) / (sigma * sigma));
    final peak = 0.85 * strength;
    const count = 16;
    final rings = <({double width, double opacity})>[];
    var before = 0.0;
    for (var i = 0; i < count; i++) {
      final w = 1 - i * 0.95 / (count - 1);
      // (what is on the page at this width once this layer is on is the target; the layer adds what is missing)
      final reach = peak * profile(w);
      // (a layer that adds less than half a percent to what is on the page already is not worth a layer: a flat brush is a few)
      if (i == 0 || reach - before > 0.006) {
        rings.add((width: w, opacity: math.max(1 - (1 - reach) / (1 - before), 0.002)));
        before = reach;
      }
    }
    final blurs = softness <= 0.05
        ? const <({double width, double opacity, double blur})>[]
        : [
            (width: (1.1 - softness).clamp(0.2, 0.95), opacity: 0.55 * strength, blur: 0.28 * softness * _p('blur')),
            (width: (0.5 - softness * 0.4667).clamp(0.08, 0.5), opacity: 0.5 * strength, blur: 0.1667 * softness * _p('blur')),
          ];
    return SoftBrush(id, name, Icons.blur_on,
        widthScale: _p('width'), rings: rings, wobble: _p('wobble'), speckle: _p('speckle'), blurs: blurs, speckleSize: _p('speckleSize'), speckleSpread: _p('speckleSpread'));
  }

  // ---- the file

  /// The `.strokedesc` as JSON: `format` ("strokedesc"), `version`, `name`, `kind` and `params`. The id is not in it (it is made of
  /// the rest); a number that is left out is the knob's standard, and `nibAngle` left out is a round tip.
  Map<String, Object?> toJson() => {
        'format': 'strokedesc',
        'version': strokeDescVersion,
        'name': name,
        'kind': kind.name,
        'params': {for (final e in params.entries) e.key: e.value},
      };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode('${const JsonEncoder.withIndent('  ').convert(toJson())}\n'));

  /// A brush from the decoded JSON of a `.strokedesc` (extra fields, such as the `listed` the library adds, are ignored).
  /// Throws [BrushDescException] for something that is not one, or from a newer version.
  factory BrushDesc.fromJson(Object? json) {
    if (json is! Map) throw const BrushDescException('This is not a brush file (it is not a JSON object).');
    if (json['format'] != 'strokedesc') throw const BrushDescException('This is not a brush file (wrong format).');
    final version = json['version'];
    if (version is! int || version < 1) throw const BrushDescException('The version of this brush file is not known.');
    if (version > strokeDescVersion) {
      throw BrushDescException('This brush file is from a newer version of Notation (file version $version); update the app to use it.');
    }
    return BrushDesc._read(json['kind'], json['params'], json['name']);
  }

  factory BrushDesc._read(Object? kindName, Object? raw, Object? name) {
    final kind = BrushKind.values.where((k) => k.name == kindName).firstOrNull;
    if (kind == null) throw BrushDescException('This brush file has a kind of brush this app does not know ("$kindName").');
    if (raw != null && raw is! Map) throw const BrushDescException('The numbers of this brush are not in the form the app writes.');
    final params = <String, double>{};
    for (final k in knobsOf(kind)) {
      final v = raw == null ? null : (raw as Map)[k.key];
      if (v == null) continue;
      if (v is! num || !v.isFinite) throw BrushDescException('"${k.key}" has to be a number.');
      params[k.key] = v.toDouble();
    }
    return BrushDesc(kind, name is String ? name : '', params);
  }

  /// The brush as a line of a live session carries it: `k` (kind), `n` (name) and `p` (numbers), no format and no version (the
  /// session has its own; a line from a newer version that this cannot read is drawn as the pen).
  Map<String, Object?> toCompactJson() => {'k': kind.name, 'n': name, 'p': {for (final e in params.entries) e.key: e.value}};

  /// A brush from [toCompactJson]. Throws [BrushDescException] for anything else.
  factory BrushDesc.fromCompactJson(Object? json) {
    if (json is! Map) throw const BrushDescException('This is not a brush.');
    return BrushDesc._read(json['k'], json['p'], json['n']);
  }

  /// A brush from the text of a `.strokedesc`.
  factory BrushDesc.parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const BrushDescException('This is not a brush file (it is not JSON).');
    }
    return BrushDesc.fromJson(json);
  }

  /// A brush from the bytes of a `.strokedesc`.
  factory BrushDesc.fromBytes(List<int> bytes) {
    if (bytes.length > strokeDescMaxBytes) throw const BrushDescException('This brush file is too big.');
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const BrushDescException('This is not a brush file (it is not text).');
    }
    return BrushDesc.parse(text);
  }

  @override
  bool operator ==(Object other) => other is BrushDesc && other.kind == kind && other.name == name && _same(other.params, params);

  static bool _same(Map<String, double> a, Map<String, double> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(kind, name, Object.hashAllUnordered(params.entries.map((e) => Object.hash(e.key, e.value))));

  // ---- where to start from

  /// Designs to start from when making a brush: the looks of the brushes the app comes with, as numbers (the soft ones are close,
  /// not the same: the app's airbrush and wash are drawn from tables, these from the numbers).
  static final List<BrushDesc> starting = List.unmodifiable([
    for (final b in [Brushes.pencil, Brushes.fountain, Brushes.calligraphy, Brushes.marker])
      BrushDesc(BrushKind.ink, b.label, {
        'width': b.params.width,
        'pressure': b.params.pressure,
        'smoothing': b.params.smoothing,
        'taper': b.params.taper,
        'opacity': b.params.opacity,
        'jitter': b.params.jitter,
        if (b.params.nibAngle != null) 'nibAngle': b.params.nibAngle!,
        'nibFlatness': b.params.nibFlatness,
      }),
    BrushDesc(BrushKind.roller, 'Roller'),
    BrushDesc(BrushKind.charcoal, 'Charcoal'),
    BrushDesc(BrushKind.soft, 'Spray', const {'width': 6, 'strength': 1, 'softness': 0.6, 'speckle': 5}),
    BrushDesc(BrushKind.soft, 'Wash', const {'width': 4, 'strength': 0.45, 'softness': 0.45, 'wobble': 0.45}),
    BrushDesc(BrushKind.ink, 'Highlighter', const {'width': 8, 'smoothing': 0.8, 'opacity': 0.45, 'blend': 1}),
    BrushDesc(BrushKind.ink, 'Shifting ink', const {'width': 2.5, 'pressure': 0.6, 'smoothing': 0.8, 'waver': 0.4, 'lightness': 0.7, 'hue': 30}),
    BrushDesc(BrushKind.stamp, 'Dots', const {'width': 4, 'spacing': 0.9, 'sizeJitter': 0.3}),
    BrushDesc(BrushKind.stamp, 'Stars', const {'width': 6, 'shape': 3, 'spacing': 1.2, 'scatter': 0.2, 'angleJitter': 1, 'lightness': 0.5, 'hue': 40}),
    BrushDesc(BrushKind.stamp, 'Leaves', const {'width': 7, 'shape': 4, 'spacing': 0.8, 'scatter': 0.3, 'follow': 1, 'angleJitter': 0.15, 'hue': 30}),
    BrushDesc(BrushKind.stamp, 'Sponge', const {'width': 5, 'spacing': 0.25, 'scatter': 0.8, 'sizeJitter': 0.8, 'opacity': 0.5}),
  ]);
}

/// The ids of the extensions whose brushes [brushIds] name and this device has not (the extension is not installed, or is switched
/// off): lines of such a brush are drawn as the pen draws them. A brush of an extension is named `ext:<extension id>/<brush id>`.
List<String> extensionsMissingFor(Iterable<String> brushIds) {
  final out = <String>{};
  for (final id in brushIds.toSet()) {
    if (!id.startsWith('ext:') || Brushes.byId(id) != null) continue;
    final slash = id.indexOf('/');
    out.add(id.substring(4, slash < 0 ? id.length : slash));
  }
  return out.toList()..sort();
}

/// The designed brushes there are on this device: their descriptions by id (a note that is saved or shared takes the ones its lines
/// use along, see `noteFileEntries`) and their place in [Brushes].
class CustomBrushes {
  CustomBrushes._();

  static final Map<String, BrushDesc> _descs = {};
  static final Map<String, Brush> _built = {};

  /// The description of the designed brush [id]; null for any other brush, or one that is not here.
  static BrushDesc? of(String id) => _descs[id];

  /// Every designed brush there is.
  static Iterable<BrushDesc> get all => _descs.values;

  /// Makes the designed brushes be [items] and no others, [listed] ones in the brush menu and the others only there for the lines
  /// that were drawn with them. A brush whose description did not change is the same brush as before (nothing is drawn again).
  static void sync(Iterable<({BrushDesc desc, bool listed})> items) {
    final next = <String, BrushDesc>{};
    final hidden = <String>{};
    for (final i in items) {
      final id = i.desc.id;
      next[id] = i.desc;
      if (!i.listed) hidden.add(id);
    }
    for (final e in next.entries) {
      if (_descs[e.key] != e.value || _built[e.key] == null) _built[e.key] = e.value.build();
    }
    _built.removeWhere((id, _) => !next.containsKey(id));
    _descs
      ..clear()
      ..addAll(next);
    Brushes.sync(customBrushPrefix, _built.values);
    Brushes.setUnlisted(hidden);
  }

  /// Keeps a brush that [learn] took in (the app sets it to put it in the library; with none the brush is there until the app is
  /// closed).
  static Future<void> Function(BrushDesc desc)? keeper;

  /// Takes in a brush that came with a line from another device (a live session): it is a brush of the app at once, not in the
  /// brush menu, and [keeper] keeps it. Does nothing, and says false, for a brush that is here already or when the library is
  /// full. The caller has checked that [desc] is the brush the line names (see [BrushDesc.id]).
  static bool learn(BrushDesc desc) {
    final id = desc.id;
    if (_descs.containsKey(id) || _descs.length >= maxLearned) return false;
    final brush = desc.build();
    _descs[id] = desc;
    _built[id] = brush;
    Brushes.setUnlisted({...Brushes.unlisted, id});
    Brushes.register(brush);
    final keep = keeper;
    if (keep != null) {
      // (a failure to keep it only means it is gone when the app is closed; the line is drawn all the same)
      keep(desc).catchError((Object _) {});
    }
    return true;
  }

  /// The most brushes there can be (a device that is sent more by someone in a session takes no more).
  static const maxLearned = 500;
}
