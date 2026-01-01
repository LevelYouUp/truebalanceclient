import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'notification_service.dart';
import 'models/notification_schedule_settings.dart';
import 'dart:async';
import 'package:workmanager/workmanager.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Background callback for WorkManager - MUST be a top-level function
// This runs when the device boots or on scheduled intervals
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      print('[WorkManager] Background task: $task');
      
      if (task == 'periodic_notification_check' || task == 'boot_complete') {
        // This task runs periodically or after reboot to ensure notifications are scheduled
        // Initialize Firebase
        try {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
        } catch (e) {
          print('[WorkManager] Firebase init: $e');
        }
        
        // Get current user
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          print('[WorkManager] User found, checking notification schedule');
          
          // Check if there's a notification scheduled
          // We'll store the next scheduled time in SharedPreferences
          final prefs = await SharedPreferences.getInstance();
          final nextNotificationStr = prefs.getString('next_notification_time');
          
          if (nextNotificationStr == null) {
            // No notification scheduled - schedule one now
            print('[WorkManager] No notification scheduled, rescheduling');
            // We can't call NotificationService.rescheduleNotification here (platform channels)
            // So we'll just flag that a reschedule is needed
            await prefs.setBool('needs_reschedule', true);
          } else {
            final nextNotification = DateTime.parse(nextNotificationStr);
            if (nextNotification.isBefore(DateTime.now())) {
              // Scheduled notification is in the past - need to reschedule
              print('[WorkManager] Scheduled notification passed, needs reschedule');
              await prefs.setBool('needs_reschedule', true);
            } else {
              print('[WorkManager] Notification scheduled for $nextNotification');
            }
          }
        }
        
        return Future.value(true);
      }
      
      return Future.value(true);
    } catch (e) {
      print('[WorkManager] Error in background task: $e');
      return Future.value(false);
    }
  });
}

class ExerciseReminderManager {
  static const String _bootCompleteTaskName = 'exerciseReminderBootComplete';

  // Initialize the reminder system
  static Future<void> initialize() async {
    if (kIsWeb) {
      print('[ExerciseReminderManager] Reminders not fully supported on web platform');
      return;
    }

    print('[ExerciseReminderManager] Initializing...');
    
    await NotificationService.initialize();
    
    // Initialize WorkManager for background tasks (reboot recovery)
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );
    
    // Register boot completion task that reschedules notifications after device reboot
    await _registerBootCompleteTask();
    
    // Schedule a periodic check every 15 minutes to ensure notifications stay scheduled
    // This is the minimum interval for Android WorkManager periodic tasks
    await _registerPeriodicCheckTask();
    
    // Schedule notifications based on user's settings
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final settings = await NotificationScheduleSettings.load();
      if (settings.enabled) {
        await updateNotificationSchedule(settings);
      }
    }
    
    print('[ExerciseReminderManager] Initialization complete');
  }

  /// Update notification schedule based on settings
  /// This is the main method that schedules notifications according to user's preferences
  static Future<void> updateNotificationSchedule(NotificationScheduleSettings settings) async {
    if (kIsWeb) return;
    
    print('[ExerciseReminderManager] Updating notification schedule...');
    print('[ExerciseReminderManager] Mode: ${settings.mode}, Enabled: ${settings.enabled}');
    
    // Cancel all existing notifications first
    await NotificationService.cancelAllNotifications();
    
    if (!settings.enabled) {
      print('[ExerciseReminderManager] Notifications disabled');
      return;
    }
    
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      print('[ExerciseReminderManager] No user logged in');
      return;
    }
    
    if (settings.mode == NotificationMode.onceDaily) {
      await _scheduleDailyNotifications(settings);
    } else {
      await _scheduleFrequentNotifications(settings);
    }
  }

  /// Schedule daily notifications at a specific time
  /// Schedules 7 notifications (one week of coverage)
  static Future<void> _scheduleDailyNotifications(NotificationScheduleSettings settings) async {
    try {
      final now = DateTime.now();
      
      // Start with today's notification time
      var notificationTime = DateTime(
        now.year,
        now.month,
        now.day,
        settings.dailyHour,
        settings.dailyMinute,
      );
      
      // If today's time has already passed, start with tomorrow
      if (notificationTime.isBefore(now)) {
        notificationTime = notificationTime.add(const Duration(days: 1));
      }
      
      // Schedule notifications for the next 7 occurrences on selected days
      int notificationId = 0;
      int daysChecked = 0;
      const maxDaysToCheck = 14; // Check up to 2 weeks to find 7 valid days
      
      while (notificationId < 7 && daysChecked < maxDaysToCheck) {
        final dayOfWeek = notificationTime.weekday; // 1=Monday, 7=Sunday
        
        if (settings.selectedDays.contains(dayOfWeek)) {
          await NotificationService.scheduleNotification(notificationTime, notificationId: notificationId);
          print('[ExerciseReminderManager] Scheduled daily notification $notificationId for $notificationTime (${_getDayName(dayOfWeek)})');
          notificationId++;
        }
        
        notificationTime = notificationTime.add(const Duration(days: 1));
        daysChecked++;
      }
      
      print('[ExerciseReminderManager] Scheduled $notificationId daily notifications at ${settings.dailyTimeFormatted}');
      print('[ExerciseReminderManager] Active days: ${settings.selectedDaysFormatted}');
    } catch (e) {
      print('[ExerciseReminderManager] Error scheduling daily notifications: $e');
    }
  }

  /// Schedule frequent notifications within a time window
  /// Schedules all notification slots for the next 7 days, constrained to the active window
  static Future<void> _scheduleFrequentNotifications(NotificationScheduleSettings settings) async {
    try {
      final now = DateTime.now();
      final intervalMinutes = settings.frequentIntervalMinutes;
      final endBoundary = now.add(const Duration(days: 7));

      // Generate all notification times for the next 7 days within the window
      final slots = _generateFrequentSlots(now, endBoundary, intervalMinutes, settings);

      var notificationId = 0;
      for (final time in slots) {
        await NotificationService.scheduleNotification(time, notificationId: notificationId);
        print('[ExerciseReminderManager] Scheduled frequent notification $notificationId for $time');
        notificationId++;
      }

      print('[ExerciseReminderManager] Scheduled ${slots.length} frequent notifications');
      print('[ExerciseReminderManager] Frequency: ${settings.frequentIntervalFormatted}, Window: ${settings.windowFormatted}');
    } catch (e) {
      print('[ExerciseReminderManager] Error scheduling frequent notifications: $e');
    }
  }

  /// Generate all frequent notification times between start and end
  static List<DateTime> _generateFrequentSlots(
    DateTime start,
    DateTime end,
    int intervalMinutes,
    NotificationScheduleSettings settings,
  ) {
    final slots = <DateTime>[];

    // Loop day by day
    for (var day = 0; day <= 7; day++) {
      final dayDate = DateTime(start.year, start.month, start.day).add(Duration(days: day));
      final dayOfWeek = dayDate.weekday; // 1=Monday, 7=Sunday
      
      // Skip if this day is not in the selected days
      if (!settings.selectedDays.contains(dayOfWeek)) {
        continue;
      }

      // Window start/end for this day
      var windowStart = DateTime(
        dayDate.year,
        dayDate.month,
        dayDate.day,
        settings.windowStartHour,
        settings.windowStartMinute,
      );

      var windowEnd = DateTime(
        dayDate.year,
        dayDate.month,
        dayDate.day,
        settings.windowEndHour,
        settings.windowEndMinute,
      );

      // Handle 24h window (start == end) as full-day coverage
      final windowIsFullDay = (settings.windowStartHour == settings.windowEndHour) &&
          (settings.windowStartMinute == settings.windowEndMinute);

      if (windowIsFullDay) {
        windowEnd = windowStart.add(const Duration(days: 1));
      } else if (_windowCrossesMidnight(settings)) {
        // Cross-midnight window: extend end to next day
        windowEnd = windowEnd.add(const Duration(days: 1));
      }

      // Skip if windowEnd before windowStart (shouldn't happen after above logic)
      if (!windowEnd.isAfter(windowStart)) continue;

      // First slot for this day
      var candidate = windowStart;

      // If today and before now, advance to next slot after now
      if (day == 0 && candidate.isBefore(start)) {
        final minutesDiff = start.difference(candidate).inMinutes;
        final steps = (minutesDiff / intervalMinutes).ceil();
        candidate = candidate.add(Duration(minutes: steps * intervalMinutes));
      }

      // Add slots within window and before global end boundary
      while (candidate.isBefore(windowEnd) && candidate.isBefore(end)) {
        slots.add(candidate);
        candidate = candidate.add(Duration(minutes: intervalMinutes));
      }
    }

    return slots;
  }

  
  static String _getDayName(int dayOfWeek) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[dayOfWeek - 1];
  }
  /// Check if a time falls within the active window
  static bool _windowCrossesMidnight(NotificationScheduleSettings settings) {
    final startMinutes = settings.windowStartHour * 60 + settings.windowStartMinute;
    final endMinutes = settings.windowEndHour * 60 + settings.windowEndMinute;
    return endMinutes < startMinutes;
  }

  // Register boot completion task (runs once after device reboot)
  static Future<void> _registerBootCompleteTask() async {
    if (kIsWeb) return;

    try {
      await Workmanager().registerOneOffTask(
        'boot_complete',
        'boot_complete',
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
  
  // Register periodic task to check notification schedule every 15 minutes
  // This ensures notifications stay scheduled even if something goes wrong
  static Future<void> _registerPeriodicCheckTask() async {
    if (kIsWeb) return;

    try {
      await Workmanager().registerPeriodicTask(
        'periodic_notification_check',
        'periodic_notification_check',
        frequency: const Duration(minutes: 15), // Minimum for Android
        constraints: Constraints(
          networkType: NetworkType.notRequired,
        ),
      );
      
      print('[ExerciseReminderManager] Periodic check task registered (every 15 minutes)');
    } catch (e) {
      print('[ExerciseReminderManager] Error registering periodic task: $e');
    }
  }

  // Call this when user completes an exercise (from your existing "Did it!" logic)
  // Now simply refreshes the notification schedule based on user's settings
  static Future<void> onExerciseCompleted() async {
    print('[ExerciseReminderManager] Exercise completed - refreshing notification schedule');

    final settings = await NotificationScheduleSettings.load();
    if (settings.enabled) {
      await updateNotificationSchedule(settings);
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
