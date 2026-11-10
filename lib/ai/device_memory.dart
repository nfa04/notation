import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// The device's memory in megabytes, or null when it cannot be told.
Future<int?> totalRamMb() async {
  if (kIsWeb) return null;
  try {
    if (Platform.isLinux) {
      // "MemTotal:       16324456 kB"
      final line = (await File('/proc/meminfo').readAsLines()).firstWhere((l) => l.startsWith('MemTotal:'));
      return int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!) ~/ 1024;
    }
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) return (await info.androidInfo).physicalRamSize;
    if (Platform.isIOS) return (await info.iosInfo).physicalRamSize;
    if (Platform.isMacOS) return (await info.macOsInfo).memorySize ~/ (1024 * 1024);
    if (Platform.isWindows) return (await info.windowsInfo).systemMemoryInMegabytes;
  } catch (_) {}
  return null;
}
