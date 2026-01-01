import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const String _needsRescheduleKey = 'needs_reschedule';

  // Initialize the notification service
  static Future<void> initialize() async {
    // Skip notification initialization on web platform
    if (kIsWeb) {
      print('Notifications not supported on web platform');
      return;
    }

    // Initialize timezone database for scheduled notifications
    try {
      tz.initializeTimeZones();
    } catch (e) {
      print('Error initializing timezone data: $e');
    }

    // Android initialization settings
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS initialization settings
    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    const InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsIOS,
        );

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Request permissions for both Android 13+ and iOS
    await requestPermissions();
  }
  // Request notification permissions (Android 13+ and iOS)
  static Future<bool> requestPermissions() async {
    if (kIsWeb) return false;

    // Request Android notification permission (Android 13+)
    final androidImplementation = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    
    if (androidImplementation != null) {
      final granted = await androidImplementation.requestNotificationsPermission();
      print('Android notification permission granted: $granted');
      if (granted == null || !granted) {
        print('User denied notification permission on Android');
        return false;
      }
    }

    // Request iOS permissions
    await _requestIOSPermissions();
    
    return true;
  }

  // Request iOS permissions
  static Future<void> _requestIOSPermissions() async {
    if (kIsWeb) return; // Skip on web

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  // Handle notification tap
  static void _onNotificationTapped(NotificationResponse response) {
    // Handle notification tap - could navigate to exercises screen
    print('Notification tapped: ${response.payload}');
  }

  // Check if notification permissions are granted
  static Future<bool> areNotificationsEnabled() async {
    if (kIsWeb) return false;

    // Check Android permission status
    final androidImplementation = _notificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    
    if (androidImplementation != null) {
      final granted = await androidImplementation.areNotificationsEnabled();
      return granted ?? false;
    }

    // For iOS, assume granted after initialization
    return true;
  }

  // Show exercise reminder notification
  static Future<void> showExerciseReminder() async {
    if (kIsWeb) {
      print('Notifications not supported on web platform');
      return;
    }

    // Check and request permissions if needed
    final hasPermission = await areNotificationsEnabled();
    if (!hasPermission) {
      print('Requesting notification permissions...');
      final granted = await requestPermissions();
      if (!granted) {
        print('Cannot show notification - permission denied');
        return;
      }
    }

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'exercise_reminders',
          'Exercise Reminders',
          channelDescription: 'Reminders to complete your daily exercises',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notificationsPlugin.show(
      0, // Notification ID
      'Time for your exercises! 💪',
      'You have exercises waiting. Complete them to maintain your progress.',
      details,
      payload: 'exercise_reminder',
    );

    print('Notification shown successfully');
  }

  // Schedule a notification at a specific time
  // notificationId: unique ID for this notification (default 0)
  static Future<void> scheduleNotification(DateTime scheduledTime, {int notificationId = 0}) async {
    if (kIsWeb) {
      print('[NotificationService] Scheduled notifications not supported on web');
      return;
    }

    // Check and request permissions if needed
    final hasPermission = await areNotificationsEnabled();
    if (!hasPermission) {
      print('[NotificationService] Cannot schedule - permission denied');
      return;
    }

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'exercise_reminders',
          'Exercise Reminders',
          channelDescription: 'Reminders to complete your daily exercises',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    try {
      final tzDateTime = tz.TZDateTime.from(scheduledTime, tz.local);
      await _notificationsPlugin.zonedSchedule(
        notificationId, // Use provided ID instead of always 0
        'Time for your exercises! 💪',
        'You have exercises waiting. Complete them to maintain your progress.',
        tzDateTime,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );

      print('[NotificationService] Notification scheduled for: $scheduledTime');
    } catch (e) {
      print('[NotificationService] Error scheduling notification: $e');
    }
  }

  // Cancel all scheduled notifications
  static Future<void> cancelAllNotifications() async {
    if (kIsWeb) return;
    await _notificationsPlugin.cancelAll();
    print('[NotificationService] All scheduled notifications cancelled');
  }
}
