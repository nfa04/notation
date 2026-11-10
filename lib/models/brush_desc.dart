import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
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

  /// Two other designed brushes drawn on the same line, one over the other ([MixBrush]); it holds them as [BrushDesc.parts].
  mix,
}

/// One number a brush is described by: its name in the file, what the person sees it called, its range and what it is when nothing
/// is said. An [optional] one can be left out (then the thing it sets is off: a round tip has no nib angle).
///
/// A [sparse] one is left out of the id of a brush when it is at its standard. Every number added to a kind after the first version
/// is sparse: the id of a brush that was made before it was there is then the id it still has, and the lines drawn with it keep their
/// look. (A number that is not sparse is part of the id always; those are the numbers the kinds had to begin with.)
///
/// An [advanced] one is shown under *Advanced*, under the heading [group] if it has one. [choices], if there are any, name the whole
/// numbers from [min] to [max] (a shape, a blend); the knob then moves in whole steps. A knob with an [own] control (the points of a
/// curve) is not given a slider.
class BrushKnob {
  final String key;
  final String label;
  final double min, max, standard;
  final bool optional, sparse, advanced, own;
  final List<String>? choices;
  final String? group;

  const BrushKnob(this.key, this.label, this.min, this.max, this.standard,
      {this.optional = false, this.sparse = false, this.advanced = false, this.own = false, this.choices, this.group});

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

  /// For a [BrushKind.mix]: the two brushes it draws, the first one's thickness being the one that is set. Empty for any other kind.
  final List<BrushDesc> parts;

  const BrushDesc._(this.kind, this.name, this.params, this.parts);

  /// The most characters of a name.
  static const maxName = 40;

  /// A brush of [kind] with [params]: a number outside the range of its knob is brought into it, one that is not given is the
  /// knob's standard, and numbers the kind does not have are left out. A mix is given its two [parts] (none: an ink and a charcoal);
  /// the parts of any other kind are left out. Throws [BrushDescException] for a mix of anything but two brushes that are not mixes.
  factory BrushDesc(BrushKind kind, String name, [Map<String, double> params = const {}, List<BrushDesc> parts = const []]) {
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
    var kept = const <BrushDesc>[];
    if (kind == BrushKind.mix) {
      if (parts.isEmpty) parts = [BrushDesc(BrushKind.ink, ''), BrushDesc(BrushKind.charcoal, '')];
      if (parts.length != 2 || parts.any((p) => p.kind == BrushKind.mix)) throw const BrushDescException('A mixed brush is made of two brushes that are not mixes themselves.');
      kept = List.unmodifiable(parts);
    }
    return BrushDesc._(kind, n.isEmpty ? defaultName(kind) : n, Map.unmodifiable(clean), kept);
  }

  static double _round(double v) => (v * 1000).round() / 1000;

  /// What a brush of [kind] is called when it has no name.
  static String defaultName(BrushKind kind) => switch (kind) {
        BrushKind.ink => 'Ink brush',
        BrushKind.roller => 'Roller brush',
        BrushKind.soft => 'Soft brush',
        BrushKind.charcoal => 'Charcoal brush',
        BrushKind.stamp => 'Stamp brush',
        BrushKind.mix => 'Mixed brush',
      };

  /// The numbers of [kind], in the order the designer shows them.
  static List<BrushKnob> knobsOf(BrushKind kind) => _knobs[kind]!;

  // (the headings of the advanced numbers)
  static const _pen = 'Pen response', _shape = 'Shape', _colour = 'Colour', _line = 'Line style', _blending = 'Blending';

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
      BrushKnob('pressureCurve', 'Pressure curve', 0.3, 3, 1, sparse: true, advanced: true, group: _pen),
      BrushKnob('speedThin', 'Thinner when fast', 0, 1, 0, sparse: true, advanced: true, group: _pen),
      BrushKnob('startTaper', 'Pointed start', 0, 1, 0.5, optional: true, sparse: true, advanced: true, group: _shape),
      BrushKnob('endTaper', 'Pointed end', 0, 1, 0.5, optional: true, sparse: true, advanced: true, group: _shape),
      BrushKnob('waver', 'Hand wobble', 0, 1, 0, sparse: true, advanced: true, group: _shape),
      BrushKnob('lightness', 'Lighter and darker', 0, 1, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('hue', 'Colour drift', 0, 60, 0, sparse: true, advanced: true, group: _colour),
      _blend,
      ..._pressureCurve,
      ..._speedCurve,
      BrushKnob('stabilise', 'Steady hand', 0, 1, 0, sparse: true, advanced: true, group: _pen),
      BrushKnob('gradientHue', 'Colour turn along the line', -180, 180, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('gradientLight', 'Lighter or darker along the line', -1, 1, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('rainbow', 'Rainbow (turn length, 0: off)', 0, 40, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('fade', 'Fade (out +, in −)', -1, 1, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('pressureShade', 'Darker where pressed', -1, 1, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('speedShade', 'Lighter where fast', -1, 1, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('dash', 'Dash length (0: solid)', 0, 8, 0, sparse: true, advanced: true, group: _line),
      BrushKnob('dashGap', 'Gap between dashes', 0.2, 8, 1.5, sparse: true, advanced: true, group: _line),
      ..._effects,
    ],
    BrushKind.roller: [
      BrushKnob('width', 'Thickness', 1, 12, 5),
      BrushKnob('coat', 'Coat', 0.1, 1, 0.5),
      BrushKnob('streaks', 'Streaks', 0, 1.5, 1),
      BrushKnob('ridge', 'Edge ridges', 0, 1, 0.35),
      BrushKnob('dryness', 'Dry lanes', 0, 0.8, 0.3),
      BrushKnob('streakLength', 'Streak length', 0.3, 3, 1, sparse: true, advanced: true, group: _shape),
      BrushKnob('laneWidth', 'Lane width', 0.4, 3, 1, sparse: true, advanced: true, group: _shape),
      BrushKnob('ridgeWidth', 'Ridge width', 0.02, 0.4, 0.14, sparse: true, advanced: true, group: _shape),
      _blend,
    ],
    BrushKind.soft: [
      BrushKnob('width', 'Thickness', 0.5, 12, 6),
      BrushKnob('strength', 'Strength', 0.1, 1, 1),
      BrushKnob('softness', 'Softness', 0, 1, 0.6),
      BrushKnob('speckle', 'Spray specks', 0, 10, 0),
      BrushKnob('wobble', 'Uneven edges', 0, 1, 0),
      BrushKnob('speckleSize', 'Speck size', 0.3, 3, 1, sparse: true, advanced: true, group: _shape),
      BrushKnob('speckleSpread', 'Speck reach', 0.3, 3, 1, sparse: true, advanced: true, group: _shape),
      BrushKnob('blur', 'Blur amount', 0, 2, 1, sparse: true, advanced: true, group: _shape),
    ],
    BrushKind.charcoal: [
      BrushKnob('width', 'Thickness', 0.5, 10, 3),
      BrushKnob('pressure', 'Pressure', 0, 1, 0.7),
      BrushKnob('taper', 'Crumbling ends', 0, 1, 0.35),
      BrushKnob('jitter', 'Rough edges', 0, 1, 0.12),
      BrushKnob('body', 'Body', 0, 0.6, 0.1),
      BrushKnob('dryness', 'Gaps in the streaks', 0, 0.8, 0.3),
      BrushKnob('dust', 'Dust', 0, 3, 1),
      BrushKnob('grainSize', 'Grain size', 0.4, 3, 1, sparse: true, advanced: true, group: _shape),
      BrushKnob('runLength', 'Streak length', 0.3, 3, 1, sparse: true, advanced: true, group: _shape),
      BrushKnob('dustSpread', 'Dust reach', 0.3, 3, 1, sparse: true, advanced: true, group: _shape),
      BrushKnob('dustSize', 'Dust size', 0.3, 3, 1, sparse: true, advanced: true, group: _shape),
    ],
    BrushKind.stamp: [
      BrushKnob('width', 'Thickness', 0.5, 12, 4, sparse: true),
      BrushKnob('spacing', 'Spacing', 0.05, 3, 0.35, sparse: true),
      BrushKnob('shape', 'Shape', 0, 4, 0, sparse: true, choices: ['Round', 'Square', 'Triangle', 'Star', 'Leaf']),
      BrushKnob('scatter', 'Scatter', 0, 2, 0, sparse: true),
      BrushKnob('sizeJitter', 'Size variation', 0, 1, 0.2, sparse: true),
      BrushKnob('opacity', 'Opacity', 0.05, 1, 1, sparse: true),
      BrushKnob('pressure', 'Pressure', 0, 1, 0.5, sparse: true, advanced: true, group: _pen),
      BrushKnob('squash', 'Flatness', 0.1, 1, 1, sparse: true, advanced: true, group: _shape),
      BrushKnob('angle', 'Angle', 0, 179, 0, sparse: true, advanced: true, group: _shape),
      BrushKnob('angleJitter', 'Angle variation', 0, 1, 0, sparse: true, advanced: true, group: _shape),
      BrushKnob('follow', 'Turns with', 0, 1, 0, sparse: true, advanced: true, group: _shape, choices: ['The page', 'The line']),
      BrushKnob('lightness', 'Lighter and darker', 0, 1, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('hue', 'Colour drift', 0, 60, 0, sparse: true, advanced: true, group: _colour),
      _blend,
      BrushKnob('gradientHue', 'Colour turn along the line', -180, 180, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('gradientLight', 'Lighter or darker along the line', -1, 1, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('rainbow', 'Rainbow (turn length, 0: off)', 0, 40, 0, sparse: true, advanced: true, group: _colour),
      BrushKnob('fade', 'Fade (out +, in −)', -1, 1, 0, sparse: true, advanced: true, group: _colour),
      ..._effects,
    ],
    BrushKind.mix: [
      BrushKnob('sizeB', 'Thickness of the second', 0.2, 4, 1),
      BrushKnob('underneath', 'The second is', 0, 1, 0, choices: ['Over the first', 'Under the first']),
    ],
  };

  static const _blend = BrushKnob('blend', 'Where lines cross', 0, 1, 0, sparse: true, advanced: true, group: _blending, choices: ['Normal', 'Darker']);

  /// The five points of the pressure curve and of the speed curve (see [BrushParams.pressurePoints]); each is there or none is.
  static const _pressureCurve = [
    BrushKnob('pressureAt0', 'Pressure: lightest touch', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
    BrushKnob('pressureAt25', 'Pressure: light', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
    BrushKnob('pressureAt50', 'Pressure: middle', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
    BrushKnob('pressureAt75', 'Pressure: firm', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
    BrushKnob('pressureAt100', 'Pressure: hardest press', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
  ];
  static const _speedCurve = [
    BrushKnob('speedAt0', 'Speed: standing still', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
    BrushKnob('speedAt25', 'Speed: slow', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
    BrushKnob('speedAt50', 'Speed: usual', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
    BrushKnob('speedAt75', 'Speed: fast', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
    BrushKnob('speedAt100', 'Speed: very fast', 0.1, 2, 1, optional: true, sparse: true, advanced: true, own: true, group: _pen),
  ];

  /// What is drawn behind a line (see [LineEffects]).
  static const _effects = [
    BrushKnob('shadow', 'Shadow', 0, 1, 0, sparse: true, advanced: true, group: _line),
    BrushKnob('shadowDistance', 'Shadow distance', 0, 3, 0.8, sparse: true, advanced: true, group: _line),
    BrushKnob('shadowBlur', 'Shadow blur', 0, 1, 0, sparse: true, advanced: true, group: _line),
    BrushKnob('glow', 'Glow', 0, 2, 0, sparse: true, advanced: true, group: _line),
    BrushKnob('glowHue', 'Glow colour turn', -180, 180, 0, sparse: true, advanced: true, group: _line),
    BrushKnob('outline', 'Border', 0, 2, 0, sparse: true, advanced: true, group: _line),
    BrushKnob('outlineTone', 'Border colour', 0, 2, 0, sparse: true, advanced: true, group: _line, choices: ['Darker', 'Lighter', 'Opposite']),
  ];

  /// The brush parts of a mix and the points of a curve are not sliders: `pressureAt…` and `speedAt…` are set together.
  static const curveSteps = ['0', '25', '50', '75', '100'];

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
    return BrushDesc(kind, name, next, parts);
  }

  /// This brush with several numbers set at once (a null value switches a number off, as in [withValue]).
  BrushDesc withValues(Map<String, double?> values) {
    final next = Map.of(params);
    for (final e in values.entries) {
      if (e.value == null) {
        next.remove(e.key);
      } else {
        next[e.key] = e.value!;
      }
    }
    return BrushDesc(kind, name, next, parts);
  }

  BrushDesc named(String newName) => BrushDesc(kind, newName, params, parts);

  /// This mix with its part [index] (0 or 1) another brush.
  BrushDesc withPart(int index, BrushDesc part) => BrushDesc(kind, name, params, [for (var i = 0; i < parts.length; i++) i == index ? part : parts[i]]);

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
    for (final p in parts) {
      text.write(';part=${p.id}');
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
            flow: _flow(),
            effects: _lineEffects(),
          ),
        );
      case BrushKind.mix:
        return MixBrush(id, name, parts[0].build(), parts[1].build(), sizeB: _p('sizeB'), underneath: _p('underneath') >= 0.5);
    }
  }

  ColourFlow _flow() => ColourFlow(
        gradientHue: _p('gradientHue'),
        gradientLight: _p('gradientLight'),
        rainbow: _p('rainbow'),
        fade: _p('fade'),
        pressureShade: kind == BrushKind.ink ? _p('pressureShade') : 0,
        speedShade: kind == BrushKind.ink ? _p('speedShade') : 0,
      );

  LineEffects _lineEffects() => LineEffects(
        dash: kind == BrushKind.ink ? _p('dash') : 0,
        dashGap: kind == BrushKind.ink ? _p('dashGap') : 1.5,
        shadow: _p('shadow'),
        shadowDistance: _p('shadowDistance'),
        shadowBlur: _p('shadowBlur'),
        glow: _p('glow'),
        glowHue: _p('glowHue'),
        outline: _p('outline'),
        outlineTone: _p('outlineTone'),
      );

  /// The points of the curve whose numbers are `<prefix>At0` … `<prefix>At100`, or null if the brush has none.
  List<double>? _curve(String prefix) {
    if (curveSteps.every((k) => params['${prefix}At$k'] == null)) return null;
    return [for (final k in curveSteps) params['${prefix}At$k'] ?? 1.0];
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
        pressurePoints: _curve('pressure'),
        speedPoints: _curve('speed'),
        stabilise: _p('stabilise'),
        flow: _flow(),
        effects: _lineEffects(),
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
        if (parts.isNotEmpty) 'parts': [for (final p in parts) p.toJson()],
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
    final parts = json['parts'];
    return BrushDesc._read(json['kind'], json['params'], json['name'], parts is List ? [for (final p in parts) BrushDesc.fromJson(_notAMix(p))] : const []);
  }

  /// [part] as it is, if it does not say it is a mix (the parts of a mix are read one level deep and no deeper).
  static Object? _notAMix(Object? part, [String kindKey = 'kind']) {
    if (part is Map && part[kindKey] == BrushKind.mix.name) throw const BrushDescException('A mixed brush is made of two brushes that are not mixes themselves.');
    return part;
  }

  factory BrushDesc._read(Object? kindName, Object? raw, Object? name, [List<BrushDesc> parts = const []]) {
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
    return BrushDesc(kind, name is String ? name : '', params, parts);
  }

  /// The brush as a line of a live session carries it: `k` (kind), `n` (name) and `p` (numbers), no format and no version (the
  /// session has its own; a line from a newer version that this cannot read is drawn as the pen).
  Map<String, Object?> toCompactJson() =>
      {'k': kind.name, 'n': name, 'p': {for (final e in params.entries) e.key: e.value}, if (parts.isNotEmpty) 'parts': [for (final p in parts) p.toCompactJson()]};

  /// A brush from [toCompactJson]. Throws [BrushDescException] for anything else.
  factory BrushDesc.fromCompactJson(Object? json) {
    if (json is! Map) throw const BrushDescException('This is not a brush.');
    final parts = json['parts'];
    return BrushDesc._read(json['k'], json['p'], json['n'], parts is List ? [for (final p in parts) BrushDesc.fromCompactJson(_notAMix(p, 'k'))] : const []);
  }

  /// What a brush starts with when it is shared as a line of text.
  static const codePrefix = 'notation-brush:';

  /// The brush as one line of text that can be sent in a message and pasted into the designer of another device (see [fromCode]):
  /// [codePrefix] and the compact JSON of the brush, URL-safe base64.
  String toCode() => '$codePrefix${base64Url.encode(utf8.encode(jsonEncode(toCompactJson()))).replaceAll('=', '')}';

  /// A brush from text that was copied from [toCode], or the text of a `.strokedesc`. Throws [BrushDescException] for anything else.
  factory BrushDesc.fromCode(String text) {
    final t = text.trim();
    if (t.length > strokeDescMaxBytes * 2) throw const BrushDescException('This is too long to be a brush.');
    if (t.startsWith('{')) return BrushDesc.parse(t);
    if (!t.startsWith(codePrefix)) throw const BrushDescException('This is not a brush (the text is not a brush code).');
    final String json;
    try {
      var body = t.substring(codePrefix.length).replaceAll(RegExp(r'\s'), '');
      while (body.length % 4 != 0) {
        body += '=';
      }
      json = utf8.decode(base64Url.decode(body));
    } on FormatException {
      throw const BrushDescException('This is not a brush (the code is damaged).');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const BrushDescException('This is not a brush (the code is damaged).');
    }
    return BrushDesc.fromCompactJson(decoded);
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
  bool operator ==(Object other) => other is BrushDesc && other.kind == kind && other.name == name && _same(other.params, params) && listEquals(other.parts, parts);

  static bool _same(Map<String, double> a, Map<String, double> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(kind, name, Object.hashAllUnordered(params.entries.map((e) => Object.hash(e.key, e.value))), Object.hashAll(parts));

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
    BrushDesc(BrushKind.ink, 'Dashed line', const {'width': 1.5, 'dash': 3, 'dashGap': 1.5}),
    BrushDesc(BrushKind.ink, 'Dotted line', const {'width': 2, 'dash': 1, 'dashGap': 1}),
    BrushDesc(BrushKind.ink, 'Neon', const {'width': 1.5, 'smoothing': 0.8, 'glow': 1.2, 'glowHue': 40}),
    BrushDesc(BrushKind.ink, 'Rainbow', const {'width': 3, 'smoothing': 0.8, 'rainbow': 14}),
    BrushDesc(BrushKind.ink, 'Comet', const {'width': 3, 'smoothing': 0.8, 'taper': 0.6, 'fade': 0.9}),
    BrushDesc(BrushKind.ink, 'Drop shadow', const {'width': 2, 'smoothing': 0.8, 'shadow': 0.5, 'shadowBlur': 0.5}),
    BrushDesc(BrushKind.ink, 'Sticker', const {'width': 3, 'smoothing': 0.8, 'outline': 0.8, 'outlineTone': 1}),
    BrushDesc(BrushKind.mix, 'Ink and charcoal', const {}, [BrushDesc(BrushKind.ink, 'Ink', {'width': 1.2, 'pressure': 0.7, 'smoothing': 0.8}), BrushDesc(BrushKind.charcoal, 'Charcoal')]),
    BrushDesc(BrushKind.mix, 'Marker with stars', const {'underneath': 1, 'sizeB': 1.5}, [
      BrushDesc(BrushKind.ink, 'Marker', {'width': 3, 'smoothing': 0.6, 'opacity': 0.5}),
      BrushDesc(BrushKind.stamp, 'Stars', {'width': 3, 'shape': 3, 'spacing': 1.5, 'hue': 40, 'lightness': 0.5}),
    ]),
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
