import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';

/// What a finger does while a pen is being used.
enum FingerMode {
  /// Writes until a pen has been seen, then only scrolls and zooms (a resting hand does not write).
  auto('Automatic'),

  /// Only scrolls and zooms; the pen writes.
  scroll('Scroll and zoom only'),

  /// Writes, always.
  draw('Write');

  final String label;
  const FingerMode(this.label);
}

/// What the button on the side of the pen does while it is held.
enum BarrelAction {
  erase('Erase'),
  lasso('Select (lasso)'),

  /// The pen takes the colour of what it touches (the eyedropper), while the button is held.
  pickColor('Pick a color'),

  /// Pressing it runs the automations of a trigger (the event "You press a trigger"); the pen does not draw with the button down.
  trigger1('Run automation trigger 1'),
  trigger2('Run automation trigger 2'),
  trigger3('Run automation trigger 3'),
  none('Nothing');

  final String label;
  const BarrelAction(this.label);

  /// Which trigger it runs (1 to 3), null for the others.
  int? get trigger => switch (this) {
        BarrelAction.trigger1 => 1,
        BarrelAction.trigger2 => 2,
        BarrelAction.trigger3 => 3,
        _ => null,
      };
}

/// How the pen is used: pressure, its button, fingers, and the ring shown where it hovers.
class StylusSettings extends ChangeNotifier {
  static const _kPressure = 'stylus_pressure';
  static const _kSensitivity = 'stylus_sensitivity';
  static const _kBarrel = 'stylus_barrel';
  static const _kFingers = 'stylus_fingers';
  static const _kHover = 'stylus_hover';
  static const _kCurve = 'stylus_curve';
  static const _kTilt = 'stylus_tilt';

  final SettingsRepository? _settings;

  StylusSettings(SettingsRepository this._settings);

  /// Remembers nothing: for tests and previews.
  StylusSettings.inMemory({bool pressure = true, double sensitivity = 0.6, BarrelAction barrel = BarrelAction.erase, FingerMode fingers = FingerMode.auto, bool hoverRing = true, double curve = 0, double tilt = 0})
      : _settings = null,
        _pressure = pressure,
        _sensitivity = sensitivity,
        _barrel = barrel,
        _fingers = fingers,
        _hoverRing = hoverRing,
        _curve = curve,
        _tilt = tilt;

  bool _pressure = true;
  double _sensitivity = 0.6;
  BarrelAction _barrel = BarrelAction.erase;
  FingerMode _fingers = FingerMode.auto;
  bool _hoverRing = true;
  double _curve = 0;
  double _tilt = 0;

  /// How the pen's pressure is answered, -1 (soft: a light touch already gives a thick line) to 1 (firm: it takes a hard press); 0 is
  /// as the pen reports it.
  double get curve => _curve;

  /// How much a leaning pen thickens the line (like the side of a pencil), 0 (not at all) to 1.
  double get tilt => _tilt;

  /// [pressure] (0 to 1) as the curve answers it: a power curve, so that 0 and 1 stay where they are.
  static double shaped(double pressure, double curve) => math.pow(pressure.clamp(0.0, 1.0), math.pow(2, curve.clamp(-1.0, 1.0) * 1.5)).toDouble();

  /// [pressure] answered by the curve, plus what the lean of the pen adds ([lean] 0 upright to 1 flat), 0 to 1.
  double response(double pressure, {double lean = 0}) => (shaped(pressure, _curve) + _tilt * lean.clamp(0.0, 1.0)).clamp(0.0, 1.0);

  /// Lines get thicker where the pen presses harder (with a pen that can tell).
  bool get pressure => _pressure;

  /// How much it matters, 0 to 1.
  double get sensitivity => _sensitivity;

  /// 0 when pressure is off, else [sensitivity].
  double get effectiveSensitivity => _pressure ? _sensitivity : 0;

  BarrelAction get barrel => _barrel;
  FingerMode get fingers => _fingers;

  /// A ring the size of the line, shown where the pen (or mouse) hovers.
  bool get hoverRing => _hoverRing;

  Future<void> load() async {
    final s = _settings;
    if (s == null) return;
    _pressure = await s.get(_kPressure) != '0';
    _sensitivity = (double.tryParse(await s.get(_kSensitivity) ?? '') ?? 0.6).clamp(0.0, 1.0);
    final barrel = await s.get(_kBarrel), fingers = await s.get(_kFingers);
    _barrel = BarrelAction.values.where((b) => b.name == barrel).firstOrNull ?? BarrelAction.erase;
    _fingers = FingerMode.values.where((b) => b.name == fingers).firstOrNull ?? FingerMode.auto;
    _hoverRing = await s.get(_kHover) != '0';
    _curve = (double.tryParse(await s.get(_kCurve) ?? '') ?? 0).clamp(-1.0, 1.0);
    _tilt = (double.tryParse(await s.get(_kTilt) ?? '') ?? 0).clamp(0.0, 1.0);
  }

  Future<void> _put(String key, String value) async {
    notifyListeners();
    await _settings?.set(key, value);
  }

  Future<void> setPressure(bool v) {
    _pressure = v;
    return _put(_kPressure, v ? '1' : '0');
  }

  Future<void> setSensitivity(double v) {
    _sensitivity = v.clamp(0.0, 1.0);
    return _put(_kSensitivity, '$_sensitivity');
  }

  Future<void> setBarrel(BarrelAction v) {
    _barrel = v;
    return _put(_kBarrel, v.name);
  }

  Future<void> setFingers(FingerMode v) {
    _fingers = v;
    return _put(_kFingers, v.name);
  }

  Future<void> setHoverRing(bool v) {
    _hoverRing = v;
    return _put(_kHover, v ? '1' : '0');
  }

  Future<void> setCurve(double v) {
    _curve = v.clamp(-1.0, 1.0);
    return _put(_kCurve, '$_curve');
  }

  Future<void> setTilt(double v) {
    _tilt = v.clamp(0.0, 1.0);
    return _put(_kTilt, '$_tilt');
  }
}
