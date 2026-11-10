import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'battery_files_io.dart' if (dart.library.js_interop) 'battery_files_web.dart';

/// What the device knows of its own power and network, each null when it cannot tell.
class BudgetReading {
  final int? batteryPercent;
  final bool? charging;
  final bool? metered;
  const BudgetReading({this.batteryPercent, this.charging, this.metered});
}

/// Whether this device should not take over a session now, and why: a battery that runs low (hosting keeps the radio busy and sends
/// everything to everybody), or a connection that is paid by the amount (the host sends each change to every guest). The device says so
/// to the host, who then leaves it off the list of successors (see `Succession.choose`). It is never a question to the person: the device
/// rules itself out, and back in, on its own.
///
/// What a device says of itself can only make it less likely to be chosen, so there is nothing to gain from saying it falsely.
///
/// - **Low battery:** at or below [lowAt] percent and not charging. It counts as fine again on the charger, or at [fineAt] percent: a
///   battery around the limit does not go back and forth.
/// - **Metered:** what the system says (Android: the active network is metered; elsewhere: the only network is a mobile one, which misses a
///   phone's hotspot reached over Wi-Fi).
class DeviceBudget extends ValueNotifier<String?> {
  static const lowAt = 20, fineAt = 30;

  /// How often the battery and the network are looked at.
  final Duration every;
  final Future<BudgetReading> Function() _read;
  Timer? _timer;
  bool _low = false;

  DeviceBudget(this._read, {this.every = const Duration(minutes: 1)}) : super(null);

  /// The battery and the network of this device, read by [readPlatform].
  factory DeviceBudget.platform() => DeviceBudget(readPlatform);

  /// Starts looking (the first look at once).
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(every, (_) => look());
    unawaited(look());
  }

  /// Looks once.
  Future<void> look() async {
    BudgetReading r;
    try {
      r = await _read();
    } catch (e) {
      debugPrint('[live] the battery and the network could not be read: $e');
      return;
    }
    if (_disposed) return;
    take(r);
  }

  /// Judges [r] (after the ones before it: see the limits above).
  void take(BudgetReading r) {
    final percent = r.batteryPercent, charging = r.charging ?? false;
    if (percent == null || charging) {
      _low = false;
    } else if (percent <= lowAt) {
      _low = true;
    } else if (percent >= fineAt) {
      _low = false;
    }
    value = _low ? 'battery' : (r.metered ?? false) ? 'metered' : null;
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// The Android and iOS side answer on this (MainActivity, AppDelegate).
  static const channel = MethodChannel('notation/device');

  /// Reads what this platform can tell. A browser tells nothing (a web page is chosen last anyway).
  static Future<BudgetReading> readPlatform() async {
    if (kIsWeb) return const BudgetReading();
    int? percent;
    bool? charging, metered;
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final m = await channel.invokeMapMethod<String, Object?>('budget');
        percent = m?['percent'] as int?;
        charging = m?['charging'] as bool?;
        metered = m?['metered'] as bool?;
      } on MissingPluginException {
        // (an older build of the native side)
      } on PlatformException catch (e) {
        debugPrint('[live] the battery could not be read: $e');
      }
    } else {
      final b = await linuxBattery();
      percent = b?.percent;
      charging = b?.charging;
    }
    if (metered == null) {
      try {
        final kinds = await Connectivity().checkConnectivity();
        metered = kinds.contains(ConnectivityResult.mobile) &&
            !kinds.any((k) => k == ConnectivityResult.wifi || k == ConnectivityResult.ethernet);
      } catch (_) {
        // (a system that cannot tell: connectivity_plus on Linux without NetworkManager)
      }
    }
    return BudgetReading(batteryPercent: percent, charging: charging, metered: metered);
  }
}
