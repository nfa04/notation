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

/// The memory a model may count on. On iOS and iPadOS the system ends an app that uses too much, long before the memory of the device
/// is used up: about 12 GB of 16 GB on an iPad Pro, with the increased-memory-limit entitlement (ios/Runner/Runner.entitlements;
/// without it about 5 GB). Seven tenths of the memory of the device is a little under that. Elsewhere the whole memory counts.
Future<int?> usableRamMb() async {
  final total = await totalRamMb();
  if (total == null) return null;
  return !kIsWeb && Platform.isIOS ? (total * 0.7).round() : total;
}
