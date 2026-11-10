import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the screen is asked for its fastest refresh rate ('1'); off unless the person turns it on.
const highRefreshSetting = 'high_refresh';

/// Below which battery level, in percent, the fast rate is given up again; empty: never.
const highRefreshBatterySetting = 'high_refresh_battery';

/// The levels the settings offer.
const highRefreshBatteryChoices = [15, 20, 30, 50];

/// To the Android side, which picks the display mode of the window and follows the battery (MainActivity).
const displayChannel = MethodChannel('notation/display');

/// Where the rate can be chosen: Android. (iOS asks for 120 Hz in its Info.plist and cannot change that while it runs; on Linux
/// Flutter draws at 60 whatever the screen.)
bool get refreshRateAdjustable => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Tells the Android side what the settings say: at the start of the app and after each change.
Future<void> applyRefreshRate(Future<String?> Function(String key) get) async {
  if (!refreshRateAdjustable) return;
  final on = await get(highRefreshSetting) == '1';
  final below = int.tryParse(await get(highRefreshBatterySetting) ?? '');
  try {
    await displayChannel.invokeMethod<void>('highRefresh', {'on': on, 'offBelowBattery': below});
  } on MissingPluginException {
    // (an older build of the Android side, or a test without it)
  } on PlatformException catch (e) {
    debugPrint('asking for the refresh rate failed: $e');
  }
}
