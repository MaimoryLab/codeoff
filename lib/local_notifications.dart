import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class LocalNotifications {
  LocalNotifications._();

  static final instance = LocalNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> initialize() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      _ready = true;
    } catch (_) {
      // Notification permission is optional; messages still work in-app.
    }
  }

  Future<void> showThreadMessage(String title, String body, String threadId) {
    if (!_ready) return Future.value();
    return _plugin.show(
      id: threadId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'thread_messages',
          'Thread messages',
          channelDescription: 'New messages from Codex threads',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: threadId,
    );
  }
}
