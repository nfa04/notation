import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'notification_sink.dart';

/// The system's notifications (Android, iOS, macOS, Linux, Windows) through `flutter_local_notifications`. Scheduling for a later time
/// works on Android, iOS and macOS only; on Linux and Windows the app shows its notifications itself while it runs.
class LocalNotificationSink implements NotificationSink {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channel = 'reminders';

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(_channel, 'Reminders', channelDescription: 'Reminders you set for notes and tasks', importance: Importance.high, priority: Priority.high),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
  );

  @override
  bool get supportsScheduling => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  @override
  Future<bool> init(void Function(String? payload) onTap) async {
    if (kIsWeb) return false;
    try {
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_notation'),
          // the permission is asked for when the person turns reminders on, not at the first start
          iOS: DarwinInitializationSettings(requestAlertPermission: false, requestSoundPermission: false, requestBadgePermission: false),
          macOS: DarwinInitializationSettings(requestAlertPermission: false, requestSoundPermission: false, requestBadgePermission: false),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(appName: 'Notation', appUserModelId: 'io.github.nfa04.notation', guid: '6f2a1d5e-7c1b-4f0e-9a43-5b1c8d2e7a10'),
        ),
        onDidReceiveNotificationResponse: (response) => onTap(response.payload),
      );
      _ready = ok != false;
      return _ready;
    } catch (_) {
      // no notification service on this system (a Linux without D-Bus, say)
      return false;
    }
  }

  @override
  Future<bool> isPermitted() async {
    if (!_ready) return false;
    try {
      if (Platform.isAndroid) {
        return await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.areNotificationsEnabled() ?? false;
      }
      if (Platform.isIOS) {
        return (await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.checkPermissions())?.isEnabled ?? false;
      }
      if (Platform.isMacOS) {
        return (await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.checkPermissions())?.isEnabled ?? false;
      }
    } catch (_) {
      return false;
    }
    return true; // Linux and Windows have no question to ask
  }

  @override
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    }
    if (Platform.isIOS) {
      return await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    }
    if (Platform.isMacOS) {
      return await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    }
    return true; // Linux and Windows have no question to ask
  }

  @override
  Future<void> show({required int id, required String title, required String body, required String payload}) async {
    if (!_ready) return;
    await _plugin.show(id: id, title: title, body: body, notificationDetails: _details, payload: payload);
  }

  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload}) async {
    if (!_ready || !supportsScheduling) return;
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(at, tz.UTC),
      notificationDetails: _details,
      // a few minutes either way is fine for a reminder, and it needs no special permission
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  @override
  Future<void> cancelScheduled() async {
    if (!_ready || !supportsScheduling) return;
    await _plugin.cancelAllPendingNotifications();
  }
}
