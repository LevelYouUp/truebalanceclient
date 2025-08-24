import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';

// Import here to avoid circular dependency
// import 'exercise_reminder_manager.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const String _lastNotificationKey = 'last_exercise_notification';

  // Initialize the notification service
  static Future<void> initialize() async {
    // Skip notification initialization on web platform
    if (kIsWeb) {
      print('Notifications not supported on web platform');
      return;
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

    // Request permissions for iOS
    await _requestIOSPermissions();
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

  // Show exercise reminder notification
  static Future<void> showExerciseReminder() async {
    if (kIsWeb) {
      print('Notifications not supported on web platform');
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

    await _notificationsPlugin.show(
      0, // Notification ID
      'Time for your exercises! 💪',
      'You have exercises waiting. Complete them to maintain your progress.',
      details,
      payload: 'exercise_reminder',
    );

    // Record the notification time
    await _recordNotificationTime();
  }

  // Record when we last sent a notification
  static Future<void> _recordNotificationTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _lastNotificationKey,
      DateTime.now().toIso8601String(),
    );
  }

  // Get the last notification time
  static Future<DateTime?> getLastNotificationTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timeString = prefs.getString(_lastNotificationKey);
    if (timeString != null) {
      return DateTime.parse(timeString);
    }
    return null;
  }

  // Check if we should send a notification
  static Future<bool> shouldSendNotification(String userId) async {
    try {
      // Check if it's been at least 24 hours since last notification
      final lastNotificationTime = await getLastNotificationTime();
      if (lastNotificationTime != null) {
        final timeSinceLastNotification = DateTime.now().difference(
          lastNotificationTime,
        );
        if (timeSinceLastNotification.inHours < 24) {
          return false; // Too soon since last notification
        }
      }

      // Get all exercise IDs for the user
      final exerciseIds = await _getAllExerciseIds(userId);
      if (exerciseIds.isEmpty) {
        return false; // No exercises assigned
      }

      // Check if user has completed any exercise in the configured interval
      final prefs = await SharedPreferences.getInstance();
      final intervalHours = prefs.getInt('notification_interval_hours') ?? 25;
      
      final lastCheckInTime = await _getLastCheckInTime(exerciseIds);
      if (lastCheckInTime != null) {
        final timeSinceLastCheckIn = DateTime.now().difference(lastCheckInTime);
        if (timeSinceLastCheckIn.inHours < intervalHours) {
          return false; // User completed an exercise recently
        }
      }

      return true; // All conditions met for sending notification
    } catch (e) {
      print('Error checking notification conditions: $e');
      return false;
    }
  }

  // Get all exercise IDs from plans and direct assignments
  static Future<List<String>> _getAllExerciseIds(String userId) async {
    final Set<String> exerciseIds = {};

    try {
      // Get exercises from plans
      final plansQuery =
          await FirebaseFirestore.instance
              .collection('exercisePlans')
              .where('userId', isEqualTo: userId)
              .get();

      for (var planDoc in plansQuery.docs) {
        final planData = planDoc.data();
        final exercises = planData['exercises'] as List<dynamic>? ?? [];
        for (var exercise in exercises) {
          if (exercise is Map<String, dynamic> && exercise['id'] != null) {
            exerciseIds.add(exercise['id'].toString());
          }
        }
      }

      // Get direct exercise assignments
      final exercisesQuery =
          await FirebaseFirestore.instance
              .collection('exercises')
              .where('userId', isEqualTo: userId)
              .get();

      for (var exerciseDoc in exercisesQuery.docs) {
        exerciseIds.add(exerciseDoc.id);
      }

      return exerciseIds.toList();
    } catch (e) {
      print('Error getting exercise IDs: $e');
      return [];
    }
  }

  // Get last check-in time across all exercises
  static Future<DateTime?> _getLastCheckInTime(List<String> exerciseIds) async {
    DateTime? lastCheckIn;

    try {
      for (String exerciseId in exerciseIds) {
        final checkInsQuery =
            await FirebaseFirestore.instance
                .collection('exercise_check_ins')
                .where('exerciseId', isEqualTo: exerciseId)
                .orderBy('timestamp', descending: true)
                .limit(1)
                .get();

        if (checkInsQuery.docs.isNotEmpty) {
          final checkInData = checkInsQuery.docs.first.data();
          final timestamp = checkInData['timestamp'] as Timestamp?;
          if (timestamp != null) {
            final checkInTime = timestamp.toDate();
            if (lastCheckIn == null || checkInTime.isAfter(lastCheckIn)) {
              lastCheckIn = checkInTime;
            }
          }
        }
      }

      return lastCheckIn;
    } catch (e) {
      print('Error getting last check-in time: $e');
      return null;
    }
  }

  // Manual check and send notification if needed
  static Future<void> checkAndSendNotification() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final shouldSend = await shouldSendNotification(user.uid);
    if (shouldSend) {
      await showExerciseReminder();
    }
  }
}
