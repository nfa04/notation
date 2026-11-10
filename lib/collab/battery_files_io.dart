import 'dart:io';

/// The battery as Linux shows it in /sys/class/power_supply: the level in percent and whether it is charging, of the first battery
/// that has a level; null when there is none (a desktop, or not Linux).
Future<({int percent, bool charging})?> linuxBattery() async {
  if (!Platform.isLinux) return null;
  try {
    final dir = Directory('/sys/class/power_supply');
    if (!await dir.exists()) return null;
    for (final e in await dir.list().toList()) {
      final type = await _read('${e.path}/type');
      if (type != 'Battery') continue;
      final percent = int.tryParse(await _read('${e.path}/capacity') ?? '');
      if (percent == null) continue;
      final status = await _read('${e.path}/status');
      // (a full battery on the charger says "Full", one that stopped at a limit "Not charging": both are on power)
      return (percent: percent, charging: status != null && status != 'Discharging' && status != 'Unknown');
    }
  } on FileSystemException {
    // (a sandbox that does not show it)
  }
  return null;
}

Future<String?> _read(String path) async {
  try {
    return (await File(path).readAsString()).trim();
  } on FileSystemException {
    return null;
  }
}
