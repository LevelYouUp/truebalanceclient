import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'notification_service.dart';
import 'dart:async';
import 'package:workmanager/workmanager.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

// Background callback for WorkManager - MUST be a top-level function
// This runs when the device boots or on scheduled intervals
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      print('[WorkManager] Background task started: $task');
      
      // Initialize Firebase if needed
      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      } catch (e) {
        // Firebase already initialized
        print('[WorkManager] Firebase already initialized or not available: $e');
      }
      
      // Initialize notification service
      await NotificationService.initialize();
      
      // Get current user from Firebase Auth persistence
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        print('[WorkManager] User authenticated: ${user.uid}');
        
        // Reschedule the next notification to ensure it's still scheduled
        // This handles cases where the user restarted their device
        await NotificationService.rescheduleNotification(user.uid);
        
        print('[WorkManager] Notification rescheduled successfully');
        return Future.value(true);
      } else {
        print('[WorkManager] No authenticated user found');
        return Future.value(true); // Not an error, user just not logged in
      }
    } catch (e) {
      print('[WorkManager] Error in background task: $e');
      return Future.value(false);
    }
  });
}

class ExerciseReminderManager {
  static const String _enabledKey = 'exercise_reminders_enabled';
  static const String _intervalHoursKey = 'notification_interval_hours';
  static const String _bootCompleteTaskName = 'exerciseReminderBootComplete';

  // Initialize the reminder system
  static Future<void> initialize() async {
    if (kIsWeb) {
      print('[ExerciseReminderManager] Reminders not fully supported on web platform');
      return;
    }

    print('[ExerciseReminderManager] Initializing...');
    
    await NotificationService.initialize();
    
    // Initialize WorkManager for background tasks (boot completion, etc.)
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );
    
    // Register boot completion task that reschedules notifications after device reboot
    await _registerBootCompleteTask();
    
    // Do an immediate reschedule for the current session
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      print('[ExerciseReminderManager] Current user found, scheduling notification');
      await NotificationService.rescheduleNotification(user.uid);
    } else {
      print('[ExerciseReminderManager] No current user, waiting for auth');
    }
    
    print('[ExerciseReminderManager] Initialization complete');
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

    print('[ExerciseReminderManager] Reminders enabled: $enabled');

    if (enabled) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await NotificationService.rescheduleNotification(user.uid);
      }
    } else {
      await NotificationService.cancelAllNotifications();
      print('[ExerciseReminderManager] All notifications cancelled');
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
    
    print('[ExerciseReminderManager] Notification interval set to $hours hours');
    
    // Reschedule notifications with the new interval
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await NotificationService.rescheduleNotification(user.uid);
    }
  }

  // Register boot completion task (runs once after device reboot)
  static Future<void> _registerBootCompleteTask() async {
    if (kIsWeb) return;

    try {
      // This task runs once when device boots (handles by Android system)
      await Workmanager().registerOneOffTask(
        _bootCompleteTaskName,
        _bootCompleteTaskName,
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        initialDelay: Duration.zero,
      );
      
      print('[ExerciseReminderManager] Boot complete task registered');
    } catch (e) {
      print('[ExerciseReminderManager] Error registering boot task: $e');
    }
  }

  // Call this when user completes an exercise (from your existing "Did it!" logic)
  static Future<void> onExerciseCompleted() async {
    // This resets the notification timer since the user just completed an exercise
    // The next notification will be scheduled based on the configured interval
    print('[ExerciseReminderManager] Exercise completed - rescheduling notifications');

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await NotificationService.rescheduleNotification(user.uid);
    }
  }

  // Manual trigger for testing
  static Future<void> triggerTestNotification() async {
    if (kIsWeb) {
      print('[ExerciseReminderManager] Test notification skipped on web platform');
      return;
    }
    print('[ExerciseReminderManager] Triggering test notification');
    await NotificationService.showExerciseReminder();
  }
}
