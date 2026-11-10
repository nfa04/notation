/// Where notifications go: the system's, or a fake in a test. Messages carry a [payload] that comes back when the person taps one.
abstract class NotificationSink {
  /// Whether the system can show a notification at a later time by itself, also when the app is not running (Android, iOS, macOS).
  /// Without it ([false]: Linux, Windows), notifications are shown by the app while it runs.
  bool get supportsScheduling;

  /// Gets ready; [onTap] is called with the payload of a notification the person selected. False: notifications are not available here.
  Future<bool> init(void Function(String? payload) onTap);

  /// Whether notifications are allowed now, without asking.
  Future<bool> isPermitted();

  /// Asks the person to allow notifications (where the system asks). The answer is whether they are allowed.
  Future<bool> requestPermission();

  /// Shows a notification now.
  Future<void> show({required int id, required String title, required String body, required String payload});

  /// Has the system show a notification at [at].
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload});

  /// Takes back every notification that was scheduled and not shown yet.
  Future<void> cancelScheduled();
}
