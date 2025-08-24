import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'notification_service.dart';
import 'dart:async';

class ExerciseReminderManager {
  static Timer? _reminderTimer;
  static const String _enabledKey = 'exercise_reminders_enabled';
  static const String _lastCheckKey = 'last_reminder_check';
  static const String _intervalHoursKey = 'notification_interval_hours';

  // Initialize the reminder system
  static Future<void> initialize() async {
    if (kIsWeb) {
      print('Exercise reminders not fully supported on web platform');
      return;
    }

    await NotificationService.initialize();
    await _startPeriodicCheck();
  }

  // Check if reminders are enabled
  static Future<bool> areRemindersEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true; // Default to enabled
  }

  // Enable or disable reminders
  static Future<void> setRemindersEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);

    if (enabled) {
      await _startPeriodicCheck();
    } else {
      await _stopPeriodicCheck();
    }
  }

  // Get notification interval in hours (default 25 hours)
  static Future<int> getNotificationIntervalHours() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_intervalHoursKey) ?? 25;
  }

  // Set notification interval in hours
  static Future<void> setNotificationIntervalHours(int hours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_intervalHoursKey, hours);
  }

  // Start periodic checking (every 30 minutes when app is active)
  static Future<void> _startPeriodicCheck() async {
    _stopPeriodicCheck(); // Cancel any existing timer

    final enabled = await areRemindersEnabled();
    if (!enabled) return;

    // Check immediately
    await _performReminderCheck();

    // Then check every 30 minutes
    _reminderTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _performReminderCheck(),
    );
  }

  // Stop periodic checking
  static Future<void> _stopPeriodicCheck() async {
    _reminderTimer?.cancel();
    _reminderTimer = null;
  }

  // Perform the actual reminder check
  static Future<void> _performReminderCheck() async {
    try {
      final enabled = await areRemindersEnabled();
      if (!enabled) return;

      // Avoid checking too frequently
      final prefs = await SharedPreferences.getInstance();
      final lastCheck = prefs.getString(_lastCheckKey);
      if (lastCheck != null) {
        final lastCheckTime = DateTime.parse(lastCheck);
        final timeSinceLastCheck = DateTime.now().difference(lastCheckTime);
        if (timeSinceLastCheck.inMinutes < 30) {
          return; // Checked too recently
        }
      }

      // Record this check
      await prefs.setString(_lastCheckKey, DateTime.now().toIso8601String());

      // Check if notification should be sent
      await NotificationService.checkAndSendNotification();
    } catch (e) {
      print('Error in reminder check: $e');
    }
  }

  // Call this when user completes an exercise (from your existing "Did it!" logic)
  static Future<void> onExerciseCompleted() async {
    // This resets the 25-hour timer since the user just completed an exercise
    // The next check will see this recent completion and won't send a notification
    print('Exercise completed - reminder timer reset');

    // Optional: You could also clear any scheduled notifications here
    // await NotificationService.cancelAllNotifications();
  }

  // Manual trigger for testing
  static Future<void> triggerTestNotification() async {
    if (kIsWeb) {
      print('Test notification skipped on web platform');
      return;
    }
    await NotificationService.showExerciseReminder();
  }

  // Dispose resources
  static void dispose() {
    _reminderTimer?.cancel();
    _reminderTimer = null;
  }
}
