import 'package:shared_preferences/shared_preferences.dart';

/// Settings for exercise reminder notifications
/// Supports two modes:
/// 1. Once Daily - notify at a specific time each day
/// 2. Frequent - notify multiple times within a time window
class NotificationScheduleSettings {
  // Keys for SharedPreferences
  static const String _enabledKey = 'notification_enabled';
  static const String _modeKey = 'notification_mode';
  static const String _dailyHourKey = 'notification_daily_hour';
  static const String _dailyMinuteKey = 'notification_daily_minute';
  static const String _frequentIntervalMinutesKey = 'notification_frequent_interval_minutes';
  static const String _windowStartHourKey = 'notification_window_start_hour';
  static const String _windowStartMinuteKey = 'notification_window_start_minute';
  static const String _windowEndHourKey = 'notification_window_end_hour';
  static const String _windowEndMinuteKey = 'notification_window_end_minute';
  static const String _selectedDaysKey = 'notification_selected_days';

  final bool enabled;
  final NotificationMode mode;
  
  // Days of week selection (1=Monday, 7=Sunday)
  final Set<int> selectedDays;
  
  // For once daily mode
  final int dailyHour; // 0-23
  final int dailyMinute; // 0-59
  
  // For frequent mode
  final int frequentIntervalMinutes; // How often to notify (e.g., 120 = every 2 hours)
  final int windowStartHour; // 0-23
  final int windowStartMinute; // 0-59
  final int windowEndHour; // 0-23
  final int windowEndMinute; // 0-59

  NotificationScheduleSettings({
    this.enabled = true,
    this.mode = NotificationMode.onceDaily,
    this.dailyHour = 9, // Default 9:00 AM
    this.dailyMinute = 0,
    this.frequentIntervalMinutes = 120, // Default every 2 hours
    this.windowStartHour = 8, // Default 8:00 AM
    this.windowStartMinute = 0,
    this.windowEndHour = 20, // Default 8:00 PM
    this.windowEndMinute = 0,
    Set<int>? selectedDays,
  }) : selectedDays = selectedDays ?? {1, 2, 3, 4, 5, 6, 7}; // Default all days

  /// Load settings from SharedPreferences
  static Future<NotificationScheduleSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    
    final daysString = prefs.getString(_selectedDaysKey);
    Set<int> selectedDays = {1, 2, 3, 4, 5, 6, 7}; // Default all days
    if (daysString != null && daysString.isNotEmpty) {
      selectedDays = daysString.split(',').map((s) => int.parse(s)).toSet();
    }
    
    return NotificationScheduleSettings(
      enabled: prefs.getBool(_enabledKey) ?? true,
      mode: NotificationMode.values[prefs.getInt(_modeKey) ?? 0],
      dailyHour: prefs.getInt(_dailyHourKey) ?? 9,
      dailyMinute: prefs.getInt(_dailyMinuteKey) ?? 0,
      frequentIntervalMinutes: prefs.getInt(_frequentIntervalMinutesKey) ?? 120,
      windowStartHour: prefs.getInt(_windowStartHourKey) ?? 8,
      windowStartMinute: prefs.getInt(_windowStartMinuteKey) ?? 0,
      windowEndHour: prefs.getInt(_windowEndHourKey) ?? 20,
      windowEndMinute: prefs.getInt(_windowEndMinuteKey) ?? 0,
      selectedDays: selectedDays,
    );
  }

  /// Save settings to SharedPreferences
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setInt(_modeKey, mode.index);
    await prefs.setInt(_dailyHourKey, dailyHour);
    await prefs.setInt(_dailyMinuteKey, dailyMinute);
    await prefs.setInt(_frequentIntervalMinutesKey, frequentIntervalMinutes);
    await prefs.setInt(_windowStartHourKey, windowStartHour);
    await prefs.setInt(_windowStartMinuteKey, windowStartMinute);
    await prefs.setInt(_windowEndHourKey, windowEndHour);
    await prefs.setInt(_windowEndMinuteKey, windowEndMinute);
    await prefs.setString(_selectedDaysKey, selectedDays.join(','));
  }

  /// Create a copy with updated values
  NotificationScheduleSettings copyWith({
    bool? enabled,
    NotificationMode? mode,
    int? dailyHour,
    int? dailyMinute,
    int? frequentIntervalMinutes,
    int? windowStartHour,
    int? windowStartMinute,
    int? windowEndHour,
    int? windowEndMinute,
    Set<int>? selectedDays,
  }) {
    return NotificationScheduleSettings(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      dailyHour: dailyHour ?? this.dailyHour,
      dailyMinute: dailyMinute ?? this.dailyMinute,
      frequentIntervalMinutes: frequentIntervalMinutes ?? this.frequentIntervalMinutes,
      windowStartHour: windowStartHour ?? this.windowStartHour,
      windowStartMinute: windowStartMinute ?? this.windowStartMinute,
      windowEndHour: windowEndHour ?? this.windowEndHour,
      windowEndMinute: windowEndMinute ?? this.windowEndMinute,
      selectedDays: selectedDays ?? this.selectedDays,
    );
  }

  /// Get a formatted string for the daily time
  String get dailyTimeFormatted {
    final hour12 = dailyHour > 12 ? dailyHour - 12 : (dailyHour == 0 ? 12 : dailyHour);
    final period = dailyHour >= 12 ? 'PM' : 'AM';
    final minute = dailyMinute.toString().padLeft(2, '0');
    return '$hour12:$minute $period';
  }

  /// Get a formatted string for the time window
  String get windowFormatted {
    final startHour12 = windowStartHour > 12 ? windowStartHour - 12 : (windowStartHour == 0 ? 12 : windowStartHour);
    final startPeriod = windowStartHour >= 12 ? 'PM' : 'AM';
    final startMinute = windowStartMinute.toString().padLeft(2, '0');
    
    final endHour12 = windowEndHour > 12 ? windowEndHour - 12 : (windowEndHour == 0 ? 12 : windowEndHour);
    final endPeriod = windowEndHour >= 12 ? 'PM' : 'AM';
    final endMinute = windowEndMinute.toString().padLeft(2, '0');
    
    return '$startHour12:$startMinute $startPeriod - $endHour12:$endMinute $endPeriod';
  }

  /// Get a formatted string for the frequent interval
  String get frequentIntervalFormatted {
    if (frequentIntervalMinutes < 60) {
      return '$frequentIntervalMinutes minutes';
    }
    final hours = frequentIntervalMinutes ~/ 60;
    final minutes = frequentIntervalMinutes % 60;
    if (minutes == 0) {
      return '$hours ${hours == 1 ? 'hour' : 'hours'}';
    }
    return '$hours ${hours == 1 ? 'hour' : 'hours'} $minutes min';
  }
  
  /// Get a formatted string for selected days
  String get selectedDaysFormatted {
    if (selectedDays.length == 7) {
      return 'Every day';
    }
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final sortedDays = selectedDays.toList()..sort();
    return sortedDays.map((d) => dayNames[d - 1]).join(', ');
  }
  
  /// Check if all days are selected
  bool get isEveryDay => selectedDays.length == 7;
}

enum NotificationMode {
  onceDaily,
  frequent,
}
