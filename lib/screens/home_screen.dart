import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../exercise_reminder_manager.dart';
import '../notification_service.dart';
import '../main.dart'; // For PainHistoryView, PlanTile, ExerciseTile, MessageButtonRow, and InactiveUserPage
import '../models/notification_schedule_settings.dart';
import 'messages_screen.dart';

// Helper class to manage congratulatory exercise state across the app
class ExerciseCongratulatoryState {
  static String? currentCongratulatoryExercise;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // Counter to force rebuild of exercise status message when exercise is completed
  int _exerciseCompletionCounter = 0;

  @override
  void initState() {
    super.initState();
    // Add lifecycle observer to check for pending reschedule when app resumes
    WidgetsBinding.instance.addObserver(this);
    
    // Clear any congratulatory text when the screen initializes/refreshes
    ExerciseCongratulatoryState.currentCongratulatoryExercise = null;
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      print('[HomeScreen] App resumed - checking for needed reschedule');
      // When app resumes, NotificationService.initialize() will check the flag
      // set by WorkManager and reschedule if needed
    }
  }

  // Method to be called when an exercise is completed
  void _onExerciseCompleted() {
    setState(() {
      _exerciseCompletionCounter++;
    });
  }

  // Helper method to check if user account is still active (for periodic checks)
  Future<Map<String, dynamic>> _checkUserStillActiveDetailed(
    String userId,
  ) async {
    try {
      final userDoc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(userId)
              .get();

      if (!userDoc.exists) {
        return {'isActive': false, 'reason': 'User document not found'};
      }

      final userData = userDoc.data() ?? {};

      // Check active flag (default to true if not set for backward compatibility)
      final isActive = userData['active'] ?? true;

      if (!isActive) {
        return {'isActive': false, 'reason': 'Account marked as inactive'};
      }

      // Check activeUntilTime if it exists
      final activeUntilTime = userData['activeUntilTime'];
      if (activeUntilTime != null) {
        DateTime? expirationTime;

        if (activeUntilTime is Timestamp) {
          expirationTime = activeUntilTime.toDate();
        } else if (activeUntilTime is String) {
          try {
            expirationTime = DateTime.parse(activeUntilTime);
          } catch (e) {
            // Invalid date format, treat as no expiration
          }
        }

        if (expirationTime != null && DateTime.now().isAfter(expirationTime)) {
          return {'isActive': false, 'reason': 'Account expired'};
        }
      }

      // Check if provider verification is required
      // Users who don't have 'activatedBy' field need provider passcode verification
      // UNLESS they are providers themselves (isAdmin: true)
      final activatedBy = userData['activatedBy'];
      if (activatedBy == null || activatedBy.toString().trim().isEmpty) {
        // Check if user is a provider - if so, they don't need external activation
        final isAdmin = userData['isAdmin'] ?? false;
        if (!isAdmin) {
          return {
            'isActive': false,
            'reason': 'Provider verification required',
          };
        }
        // Provider users are considered self-activated
      }

      return {'isActive': true, 'reason': 'Account is active and verified'};
    } catch (e) {
      return {'isActive': false, 'reason': 'Error checking account status: $e'};
    }
  }

  // Helper method to get all exercise IDs from plans and direct assignments
  Future<List<String>> _getAllExerciseIds(String userId) async {
    final userDoc =
        await FirebaseFirestore.instance.collection('users').doc(userId).get();

    final userData = userDoc.data() ?? {};
    final planIds = List<String>.from(userData['planIds'] ?? []);
    final directExerciseIds = List<String>.from(userData['exerciseIds'] ?? []);

    Set<String> allExerciseIds = directExerciseIds.toSet();

    // Get exercises from plans
    for (String planId in planIds) {
      final planDoc =
          await FirebaseFirestore.instance
              .collection('plans')
              .doc(planId)
              .get();

      final planData = planDoc.data() ?? {};

      // Handle both old and new data structures
      if (planData.containsKey('exercises') && planData['exercises'] is List) {
        final exercisesList = List<Map<String, dynamic>>.from(
          (planData['exercises'] as List).map((e) => e as Map<String, dynamic>),
        );
        for (var exercise in exercisesList) {
          if (exercise['exerciseId'] != null) {
            allExerciseIds.add(exercise['exerciseId'] as String);
          }
        }
      } else if (planData.containsKey('exerciseIds') &&
          planData['exerciseIds'] is List) {
        final exerciseIds = List<String>.from(planData['exerciseIds'] ?? []);
        allExerciseIds.addAll(exerciseIds);
      }
    }

    return allExerciseIds.toList();
  }

  // Helper method to get last check-in time across all exercises
  Future<DateTime?> _getLastCheckInTime(
    String userId,
    List<String> exerciseIds,
  ) async {
    if (exerciseIds.isEmpty) return null;

    final checkInsQuery =
        await FirebaseFirestore.instance
            .collection('exercise_check_ins')
            .where('userId', isEqualTo: userId)
            .where(
              'exerciseId',
              whereIn: exerciseIds.take(10).toList(),
            ) // Firestore limit
            .get();

    DateTime? latestCheckIn;

    for (var doc in checkInsQuery.docs) {
      final data = doc.data();
      final timestamp = data['timestamp'];

      DateTime? checkInTime;
      if (timestamp is Timestamp) {
        checkInTime = timestamp.toDate();
      }

      if (checkInTime != null) {
        if (latestCheckIn == null || checkInTime.isAfter(latestCheckIn)) {
          latestCheckIn = checkInTime;
        }
      }
    }

    // If we have more than 10 exercises, check the remaining ones
    if (exerciseIds.length > 10) {
      for (int i = 10; i < exerciseIds.length; i += 10) {
        final batch = exerciseIds.skip(i).take(10).toList();
        final batchQuery =
            await FirebaseFirestore.instance
                .collection('exercise_check_ins')
                .where('userId', isEqualTo: userId)
                .where('exerciseId', whereIn: batch)
                .get();

        for (var doc in batchQuery.docs) {
          final data = doc.data();
          final timestamp = data['timestamp'];

          DateTime? checkInTime;
          if (timestamp is Timestamp) {
            checkInTime = timestamp.toDate();
          }

          if (checkInTime != null) {
            if (latestCheckIn == null || checkInTime.isAfter(latestCheckIn)) {
              latestCheckIn = checkInTime;
            }
          }
        }
      }
    }

    return latestCheckIn;
  }

  // Helper method to format time difference
  String _formatTimeDifference(DateTime lastTime) {
    final now = DateTime.now();
    final difference = now.difference(lastTime);

    if (difference.inDays >= 14) {
      final weeks = (difference.inDays / 7).floor();
      return weeks == 1 ? 'a week' : '$weeks weeks';
    } else if (difference.inDays >= 1) {
      return difference.inDays == 1 ? 'a day' : '${difference.inDays} days';
    } else if (difference.inHours >= 1) {
      if (difference.inHours == 1) {
        return 'an hour';
      } else if (difference.inMinutes <= 90) {
        return 'an hour and a half';
      } else {
        return '${difference.inHours} hours';
      }
    } else if (difference.inMinutes >= 30) {
      return 'half an hour';
    } else if (difference.inMinutes > 1) {
      return '${difference.inMinutes} minutes';
    } else {
      return 'moments';
    }
  }

  // Helper method to build compact buttons for landscape mode
  Widget _buildCompactButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(fontSize: 12),
      ),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          vertical: 10,
          horizontal: 12,
        ),
        minimumSize: const Size(100, 36),
      ),
      onPressed: onPressed,
    );
  }

  // Helper method to get exercise status message
  Future<String> _getExerciseStatusMessage(String userId) async {
    try {
      final allExerciseIds = await _getAllExerciseIds(userId);

      if (allExerciseIds.isEmpty) {
        return '';
      }

      final lastCheckIn = await _getLastCheckInTime(userId, allExerciseIds);

      if (lastCheckIn == null) {
        // No check-ins yet
        final count = allExerciseIds.length;
        if (count == 1) {
          return '1 new exercise is ready for you!';
        } else {
          return '$count new exercises are ready for you!';
        }
      } else {
        // Has check-ins, show time since last
        final timeDiff = _formatTimeDifference(lastCheckIn);
        return "It's been $timeDiff since your last set";
      }
    } catch (e) {
      return '';
    }
  }

  // Helper method to get unread provider messages count and latest timestamp
  Future<Map<String, dynamic>> _getUnreadMessageInfo(String userId) async {
    try {
      final messagesQuery =
          await FirebaseFirestore.instance
              .collection('messages')
              .where('userId', isEqualTo: userId)
              .where('fromAdmin', isEqualTo: true)
              .get();

      final unreadMessages =
          messagesQuery.docs.where((doc) {
            final data = doc.data();
            // Consider unread if read field doesn't exist or is false
            return !data.containsKey('read') || data['read'] != true;
          }).toList();

      final unreadCount = unreadMessages.length;

      if (unreadCount == 0) {
        return {'count': 0, 'latestTimestamp': null};
      }

      // Find the latest unread message timestamp
      DateTime? latestTimestamp;
      for (var doc in unreadMessages) {
        final data = doc.data();
        final timestamp = data['timestamp'];

        DateTime? messageTime;
        if (timestamp is Timestamp) {
          messageTime = timestamp.toDate();
        } else if (timestamp is String) {
          try {
            messageTime = DateTime.parse(timestamp);
          } catch (_) {}
        }

        if (messageTime != null) {
          if (latestTimestamp == null || messageTime.isAfter(latestTimestamp)) {
            latestTimestamp = messageTime;
          }
        }
      }

      return {'count': unreadCount, 'latestTimestamp': latestTimestamp};
    } catch (e) {
      return {'count': 0, 'latestTimestamp': null};
    }
  }

  // Helper method to mark all provider messages as read
  Future<void> _markProviderMessagesAsRead(String userId) async {
    try {
      final unreadMessagesQuery =
          await FirebaseFirestore.instance
              .collection('messages')
              .where('userId', isEqualTo: userId)
              .where('fromAdmin', isEqualTo: true)
              .get();

      final batch = FirebaseFirestore.instance.batch();

      for (var doc in unreadMessagesQuery.docs) {
        final data = doc.data();
        // Only update if read field doesn't exist or is false
        if (!data.containsKey('read') || data['read'] != true) {
          batch.update(doc.reference, {'read': true});
        }
      }

      await batch.commit();
    } catch (e) {
      // Handle error silently
    }
  }

  // Helper method to format time since message
  String _formatMessageTime(DateTime messageTime) {
    final now = DateTime.now();
    final difference = now.difference(messageTime);

    if (difference.inDays >= 1) {
      return difference.inDays == 1
          ? 'yesterday'
          : '${difference.inDays} days ago';
    } else if (difference.inHours >= 1) {
      return difference.inHours == 1
          ? 'an hour ago'
          : '${difference.inHours} hours ago';
    } else if (difference.inMinutes >= 5) {
      return '${difference.inMinutes} minutes ago';
    } else if (difference.inMinutes >= 1) {
      return 'a few minutes ago';
    } else {
      return 'just now';
    }
  }

  // Pain tracking methods
  Future<void> _showAddPainLevelDialog(
    BuildContext context,
    String userId,
  ) async {
    // Fetch the user's most recent pain level
    int? selectedPainLevel;
    try {
      final lastPainQuery = await FirebaseFirestore.instance
          .collection('painLevels')
          .where('userId', isEqualTo: userId)
          .get();
      
      if (lastPainQuery.docs.isNotEmpty) {
        // Sort by timestamp in memory to avoid composite index requirement
        final docs = lastPainQuery.docs.toList();
        docs.sort((a, b) {
          final aData = a.data();
          final bData = b.data();
          final aTimestamp = aData['timestamp'];
          final bTimestamp = bData['timestamp'];
          
          DateTime? aTime, bTime;
          if (aTimestamp is Timestamp) {
            aTime = aTimestamp.toDate();
          }
          if (bTimestamp is Timestamp) {
            bTime = bTimestamp.toDate();
          }
          
          if (aTime == null || bTime == null) return 0;
          return bTime.compareTo(aTime); // Descending order
        });
        
        // Get the most recent pain level
        final lastPainData = docs.first.data();
        selectedPainLevel = lastPainData['painLevel'];
      }
    } catch (e) {
      // If error, selectedPainLevel remains null
      print('Could not fetch last pain level: $e');
    }
    
    final TextEditingController notesController = TextEditingController();

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Add Pain Level'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Rate your current pain level (0 = none, 10 = severe):',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: List.generate(11, (index) {
                        final level = index;
                        final isSelected = selectedPainLevel == level;
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              selectedPainLevel = level;
                            });
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _getPainLevelColor(level),
                              border: Border.all(
                                color: isSelected ? Colors.black : Colors.white,
                                width: isSelected ? 3 : 1,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.3),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2),
                                      )
                                    ]
                                  : null,
                            ),
                            child: Center(
                              child: Text(
                                level.toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: notesController,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                        border: OutlineInputBorder(),
                        hintText: 'Describe your pain or activities...',
                      ),
                      maxLines: 3,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
                ElevatedButton(
                  child: const Text('Save'),
                  onPressed: () async {
                    if (selectedPainLevel == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please select a pain level'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                      return;
                    }
                    await _savePainLevel(
                      userId,
                      selectedPainLevel!,
                      notesController.text.trim(),
                    );
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Pain level $selectedPainLevel recorded'),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Color _getPainLevelColor(int level) {
    // Color gradient: green (0) > yellow > orange > red > darkest red (10)
    switch (level) {
      case 0:
        return const Color(0xFF4CAF50); // Green - only green, no pain
      case 1:
        return const Color(0xFFFDD835); // Bright yellow
      case 2:
        return const Color(0xFFFBC02D); // Yellow
      case 3:
        return const Color(0xFFF9A825); // Deep yellow
      case 4:
        return const Color(0xFFF57C00); // Orange
      case 5:
        return const Color(0xFFEF6C00); // Deep orange
      case 6:
        return const Color(0xFFE65100); // Dark orange
      case 7:
        return const Color(0xFFD84315); // Red-orange
      case 8:
        return const Color(0xFFC62828); // Red
      case 9:
        return const Color(0xFFB71C1C); // Dark red
      case 10:
        return const Color(0xFF8B0000); // Darkest angriest red
      default:
        return Colors.grey;
    }
  }

  Future<void> _savePainLevel(
    String userId,
    int painLevel,
    String notes,
  ) async {
    try {
      await FirebaseFirestore.instance.collection('painLevels').add({
        'userId': userId,
        'painLevel': painLevel,
        'notes': notes,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error saving pain level: $e');
    }
  }

  void _showPainHistoryDialog(BuildContext context, String userId) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final screenHeight = MediaQuery.of(context).size.height;
              final screenWidth = MediaQuery.of(context).size.width;

              // Adjust dialog height based on screen orientation
              final dialogHeight =
                  screenHeight < screenWidth
                      ? screenHeight *
                          0.85 // Landscape - more compact
                      : screenHeight * 0.8; // Portrait - standard

              return Container(
                width: double.maxFinite,
                height: dialogHeight,
                padding: const EdgeInsets.all(16),
                child: PainHistoryView(userId: userId),
              );
            },
          ),
        );
      },
    );
  }

  // Helper method to build day of week toggle button
  Widget _buildDayToggle(
    String label,
    int dayNumber,
    NotificationScheduleSettings settings,
    Function(NotificationScheduleSettings) onToggle,
  ) {
    final isSelected = settings.selectedDays.contains(dayNumber);
    
    return Flexible(
      child: InkWell(
        onTap: () {
          final newDays = Set<int>.from(settings.selectedDays);
          if (isSelected) {
            // Don't allow deselecting if it's the last day
            if (newDays.length > 1) {
              newDays.remove(dayNumber);
            }
          } else {
            newDays.add(dayNumber);
          }
          onToggle(settings.copyWith(selectedDays: newDays));
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 50),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.deepPurple : Colors.grey[600],
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Notification settings dialog
  void _showNotificationSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        NotificationScheduleSettings? localSettings;
        bool hasChanges = false;
        bool isSaving = false;
        
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Exercise Reminder Settings'),
              content: FutureBuilder<NotificationScheduleSettings>(
                future: NotificationScheduleSettings.load(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const SizedBox(
                      height: 100,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  // Initialize local settings on first load
                  localSettings ??= snapshot.data!;
                  final settings = localSettings!;

                  return SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Choose when you want to receive exercise reminders.',
                          style: TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 16),
                        
                        // Enable/Disable switch
                        SwitchListTile(
                          title: const Text('Enable Exercise Reminders'),
                          subtitle: Text(
                            settings.enabled
                                ? 'You will receive notifications'
                                : 'No notifications will be sent',
                          ),
                          value: settings.enabled,
                          onChanged: (bool value) {
                            setState(() {
                              localSettings = settings.copyWith(enabled: value);
                              hasChanges = true;
                            });
                          },
                        ),
                        
                        if (settings.enabled) ...[
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 16),
                          
                          // Days of week selection
                          const Text(
                            'Active Days:',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _buildDayToggle('M', 1, settings, (updatedSettings) {
                                setState(() {
                                  localSettings = updatedSettings;
                                  hasChanges = true;
                                });
                              }),
                              _buildDayToggle('T', 2, settings, (updatedSettings) {
                                setState(() {
                                  localSettings = updatedSettings;
                                  hasChanges = true;
                                });
                              }),
                              _buildDayToggle('W', 3, settings, (updatedSettings) {
                                setState(() {
                                  localSettings = updatedSettings;
                                  hasChanges = true;
                                });
                              }),
                              _buildDayToggle('T', 4, settings, (updatedSettings) {
                                setState(() {
                                  localSettings = updatedSettings;
                                  hasChanges = true;
                                });
                              }),
                              _buildDayToggle('F', 5, settings, (updatedSettings) {
                                setState(() {
                                  localSettings = updatedSettings;
                                  hasChanges = true;
                                });
                              }),
                              _buildDayToggle('S', 6, settings, (updatedSettings) {
                                setState(() {
                                  localSettings = updatedSettings;
                                  hasChanges = true;
                                });
                              }),
                              _buildDayToggle('S', 7, settings, (updatedSettings) {
                                setState(() {
                                  localSettings = updatedSettings;
                                  hasChanges = true;
                                });
                              }),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Center(
                            child: Text(
                              settings.selectedDaysFormatted,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 16),
                          
                          // Mode selection
                          const Text(
                            'Notification Schedule:',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 12),
                          
                          // Once Daily option
                          RadioListTile<NotificationMode>(
                            title: const Text('Once Daily'),
                            subtitle: Text(
                              settings.mode == NotificationMode.onceDaily
                                  ? 'At ${settings.dailyTimeFormatted}'
                                  : 'Reminder at a specific time each day',
                              style: TextStyle(
                                fontSize: 12,
                                color: settings.mode == NotificationMode.onceDaily
                                    ? Colors.deepPurple
                                    : Colors.grey,
                              ),
                            ),
                            value: NotificationMode.onceDaily,
                            groupValue: settings.mode,
                            onChanged: (NotificationMode? value) {
                              if (value != null) {
                                setState(() {
                                  localSettings = settings.copyWith(mode: value);
                                  hasChanges = true;
                                });
                              }
                            },
                          ),
                          
                          // Daily time picker
                          if (settings.mode == NotificationMode.onceDaily)
                            Padding(
                              padding: const EdgeInsets.only(left: 32, right: 16, bottom: 8),
                              child: Row(
                                children: [
                                  const Text('Time: '),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: () async {
                                      final TimeOfDay? picked = await showTimePicker(
                                        context: context,
                                        initialTime: TimeOfDay(
                                          hour: settings.dailyHour,
                                          minute: settings.dailyMinute,
                                        ),
                                      );
                                      if (picked != null) {
                                        setState(() {
                                          localSettings = settings.copyWith(
                                            dailyHour: picked.hour,
                                            dailyMinute: picked.minute,
                                          );
                                          hasChanges = true;
                                        });
                                      }
                                    },
                                    child: Text(
                                      settings.dailyTimeFormatted,
                                      style: const TextStyle(fontSize: 16),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          
                          const SizedBox(height: 8),
                          
                          // Frequent option
                          RadioListTile<NotificationMode>(
                            title: const Text('More Frequent'),
                            subtitle: Text(
                              settings.mode == NotificationMode.frequent
                                  ? 'Every ${settings.frequentIntervalFormatted}, ${settings.windowFormatted}'
                                  : 'Multiple reminders during specific hours',
                              style: TextStyle(
                                fontSize: 12,
                                color: settings.mode == NotificationMode.frequent
                                    ? Colors.deepPurple
                                    : Colors.grey,
                              ),
                            ),
                            value: NotificationMode.frequent,
                            groupValue: settings.mode,
                            onChanged: (NotificationMode? value) {
                              if (value != null) {
                                setState(() {
                                  localSettings = settings.copyWith(mode: value);
                                  hasChanges = true;
                                });
                              }
                            },
                          ),
                          
                          // Frequent mode settings
                          if (settings.mode == NotificationMode.frequent)
                            Padding(
                              padding: const EdgeInsets.only(left: 32, right: 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Frequency dropdown
                                  const Text(
                                    'Frequency:',
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Colors.grey),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<int>(
                                        value: settings.frequentIntervalMinutes,
                                        isExpanded: true,
                                        items: [
                                          DropdownMenuItem(value: 30, child: Text('Every 30 minutes')),
                                          DropdownMenuItem(value: 60, child: Text('Every hour')),
                                          DropdownMenuItem(value: 90, child: Text('Every 1.5 hours')),
                                          DropdownMenuItem(value: 120, child: Text('Every 2 hours')),
                                          DropdownMenuItem(value: 180, child: Text('Every 3 hours')),
                                          DropdownMenuItem(value: 240, child: Text('Every 4 hours')),
                                        ],
                                        onChanged: (int? value) {
                                          if (value != null) {
                                            setState(() {
                                              localSettings = settings.copyWith(frequentIntervalMinutes: value);
                                              hasChanges = true;
                                            });
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  
                                  // Time window
                                  const Text(
                                    'Active Hours:',
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () async {
                                            final TimeOfDay? picked = await showTimePicker(
                                              context: context,
                                              initialTime: TimeOfDay(
                                                hour: settings.windowStartHour,
                                                minute: settings.windowStartMinute,
                                              ),
                                              helpText: 'Start Time',
                                            );
                                            if (picked != null) {
                                              setState(() {
                                                localSettings = settings.copyWith(
                                                  windowStartHour: picked.hour,
                                                  windowStartMinute: picked.minute,
                                                );
                                                hasChanges = true;
                                              });
                                            }
                                          },
                                          child: Column(
                                            children: [
                                              const Text('From', style: TextStyle(fontSize: 10)),
                                              Text(
                                                '${settings.windowStartHour > 12 ? settings.windowStartHour - 12 : (settings.windowStartHour == 0 ? 12 : settings.windowStartHour)}:${settings.windowStartMinute.toString().padLeft(2, '0')} ${settings.windowStartHour >= 12 ? 'PM' : 'AM'}',
                                                style: const TextStyle(fontSize: 14),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      const Icon(Icons.arrow_forward, size: 16),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () async {
                                            final TimeOfDay? picked = await showTimePicker(
                                              context: context,
                                              initialTime: TimeOfDay(
                                                hour: settings.windowEndHour,
                                                minute: settings.windowEndMinute,
                                              ),
                                              helpText: 'End Time',
                                            );
                                            if (picked != null) {
                                              setState(() {
                                                localSettings = settings.copyWith(
                                                  windowEndHour: picked.hour,
                                                  windowEndMinute: picked.minute,
                                                );
                                                hasChanges = true;
                                              });
                                            }
                                          },
                                          child: Column(
                                            children: [
                                              const Text('To', style: TextStyle(fontSize: 10)),
                                              Text(
                                                '${settings.windowEndHour > 12 ? settings.windowEndHour - 12 : (settings.windowEndHour == 0 ? 12 : settings.windowEndHour)}:${settings.windowEndMinute.toString().padLeft(2, '0')} ${settings.windowEndHour >= 12 ? 'PM' : 'AM'}',
                                                style: const TextStyle(fontSize: 14),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 16),
                          
                          // Test notification button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.notifications_active),
                              label: const Text('Test Notification'),
                              onPressed: () async {
                                final hasPermission = await NotificationService.areNotificationsEnabled();
                                
                                if (!hasPermission) {
                                  final granted = await NotificationService.requestPermissions();
                                  if (!granted) {
                                    Navigator.of(context).pop();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Notification permission denied. Please enable notifications in your device settings.'),
                                        duration: Duration(seconds: 4),
                                      ),
                                    );
                                    return;
                                  }
                                }
                                
                                await ExerciseReminderManager.triggerTestNotification();
                                Navigator.of(context).pop();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Test notification sent! Check your notification tray.'),
                                    duration: Duration(seconds: 3),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: isSaving ? null : () {
                    Navigator.of(context).pop();
                  },
                ),
                TextButton(
                  child: isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                  onPressed: isSaving ? null : () async {
                    if (localSettings != null && hasChanges) {
                      setState(() {
                        isSaving = true;
                      });
                      
                      try {
                        await localSettings!.save();
                        await ExerciseReminderManager.updateNotificationSchedule(localSettings!);
                      } finally {
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      }
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Image.asset(
          'assets/images/TRUEBALANCE-PAINRELIEF_LOGO_DARK_2256x504.png',
          height: 40,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return const Text(
              'TrueBalance Client',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            );
          },
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot>(
          stream:
              FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
          final userData = snapshot.data!.data() as Map<String, dynamic>? ?? {};

          // Check if user is still active whenever user data changes
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            final activeStatus = await _checkUserStillActiveDetailed(user.uid);
            if (!activeStatus['isActive']) {
              // User account has been deactivated, navigate to inactive user page
              if (mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(
                    builder:
                        (context) =>
                            InactiveUserPage(reason: activeStatus['reason']),
                  ),
                  (route) => false,
                );
              }
            }
          });

          final planIds = List<String>.from(userData['planIds'] ?? []);
          final exerciseIds = List<String>.from(userData['exerciseIds'] ?? []);
          final name = (userData['name'] as String?)?.trim() ?? '';
          final nameController = TextEditingController(text: name);

          // If no plans and no exercises, show name display/edit above empty state
          if (planIds.isEmpty && exerciseIds.isEmpty) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name.isNotEmpty
                                  ? 'Hi $name!'
                                  : 'Hi Anonymous User! What\'s your name?',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          // Only show edit button if no name is set
                          if (name.isEmpty)
                            IconButton(
                              icon: const Icon(Icons.edit),
                              tooltip: 'Set Name',
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (ctx) {
                                    return AlertDialog(
                                      title: const Text('Set Your Name'),
                                      content: TextField(
                                        controller: nameController,
                                        decoration: const InputDecoration(
                                          labelText: 'Enter your name',
                                        ),
                                        autofocus: true,
                                      ),
                                      actions: [
                                        TextButton(
                                          child: const Text('Cancel'),
                                          onPressed:
                                              () => Navigator.of(ctx).pop(),
                                        ),
                                        ElevatedButton(
                                          child: const Text('Save'),
                                          onPressed: () async {
                                            final newName =
                                                nameController.text.trim();
                                            if (newName.isNotEmpty) {
                                              await FirebaseFirestore.instance
                                                  .collection('users')
                                                  .doc(user.uid)
                                                  .set({
                                                    'name': newName,
                                                  }, SetOptions(merge: true));
                                              Navigator.of(ctx).pop();
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Name set! To change it later, please message your provider.',
                                                  ),
                                                ),
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    );
                                  },
                                );
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.info_outline,
                            size: 64,
                            color: Colors.grey,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'You have no assigned plans or exercises yet.',
                            style: const TextStyle(
                              fontSize: 18,
                              color: Colors.grey,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          // Footer buttons - responsive layout
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
                              
                              if (isLandscape) {
                                // Landscape: Show all buttons in a single row with wrap
                                return Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  alignment: WrapAlignment.center,
                                  children: [
                                    _buildCompactButton(
                                      icon: Icons.add_circle_outline,
                                      label: 'Add Pain',
                                      onPressed: () async {
                                        await _showAddPainLevelDialog(context, user.uid);
                                      },
                                    ),
                                    _buildCompactButton(
                                      icon: Icons.history,
                                      label: 'Pain History',
                                      onPressed: () {
                                        _showPainHistoryDialog(context, user.uid);
                                      },
                                    ),
                                    _buildCompactButton(
                                      icon: Icons.notifications_active,
                                      label: 'Send Nudge',
                                      onPressed: () async {
                                        final now = DateTime.now();
                                        await FirebaseFirestore.instance
                                            .collection('users')
                                            .doc(user.uid)
                                            .set({
                                              'nudge': 1,
                                              'lastNudge': now.toIso8601String(),
                                            }, SetOptions(merge: true));
                                        final formattedTime =
                                            '${now.month}/${now.day}/${now.year} at ${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Nudge sent on $formattedTime')),
                                        );
                                      },
                                    ),
                                    _buildCompactButton(
                                      icon: Icons.message_outlined,
                                      label: 'Message',
                                      onPressed: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (context) => MessagesScreen(user: user),
                                          ),
                                        );
                                      },
                                    ),
                                    _buildCompactButton(
                                      icon: Icons.notifications_outlined,
                                      label: 'Settings',
                                      onPressed: () {
                                        _showNotificationSettingsDialog(context);
                                      },
                                    ),
                                  ],
                                );
                              } else {
                                // Portrait: Show in rows as before
                                return Column(
                                  children: [
                                    // Pain tracking buttons
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 400),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: ElevatedButton.icon(
                                              icon: const Icon(Icons.add_circle_outline),
                                              label: const Text(
                                                'Add Pain Level',
                                                textAlign: TextAlign.center,
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                padding: const EdgeInsets.symmetric(
                                                  vertical: 12,
                                                  horizontal: 8,
                                                ),
                                              ),
                                              onPressed: () async {
                                                await _showAddPainLevelDialog(
                                                  context,
                                                  user.uid,
                                                );
                                              },
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: ElevatedButton.icon(
                                              icon: const Icon(Icons.history),
                                              label: const Text(
                                                'View Pain History',
                                                textAlign: TextAlign.center,
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                padding: const EdgeInsets.symmetric(
                                                  vertical: 12,
                                                  horizontal: 8,
                                                ),
                                              ),
                                              onPressed: () {
                                                _showPainHistoryDialog(context, user.uid);
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    // Notification settings button
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 400),
                                      child: ElevatedButton.icon(
                                        icon: const Icon(Icons.notifications_outlined),
                                        label: const Text(
                                          'Exercise Reminder Settings',
                                          textAlign: TextAlign.center,
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                            horizontal: 16,
                                          ),
                                        ),
                                        onPressed: () {
                                          _showNotificationSettingsDialog(context);
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    // Communication buttons with independent message input
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 400),
                                      child: MessageButtonRow(
                                        user: user,
                                        getUnreadMessageInfo: _getUnreadMessageInfo,
                                        markProviderMessagesAsRead:
                                            _markProviderMessagesAsRead,
                                        formatMessageTime: _formatMessageTime,
                                      ),
                                    ),
                                  ],
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          }

          // Show plans and then exercises, plus name display/edit with exercise status
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: FutureBuilder<String>(
                        key: ValueKey(_exerciseCompletionCounter),
                        future: _getExerciseStatusMessage(user.uid),
                        builder: (context, snapshot) {
                          final greeting =
                              name.isNotEmpty
                                  ? 'Hi $name!'
                                  : 'Hi Anonymous User! What\'s your name?';
                          final statusMessage =
                              snapshot.hasData && snapshot.data!.isNotEmpty
                                  ? ' ${snapshot.data!}'
                                  : '';
                          return Text(
                            '$greeting$statusMessage',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          );
                        },
                      ),
                    ),
                    // Only show edit button if no name is set
                    if (name.isEmpty)
                      IconButton(
                        icon: const Icon(Icons.edit),
                        tooltip: 'Set Name',
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (ctx) {
                              return AlertDialog(
                                title: const Text('Set Your Name'),
                                content: TextField(
                                  controller: nameController,
                                  decoration: const InputDecoration(
                                    labelText: 'Enter your name',
                                  ),
                                  autofocus: true,
                                ),
                                actions: [
                                  TextButton(
                                    child: const Text('Cancel'),
                                    onPressed: () => Navigator.of(ctx).pop(),
                                  ),
                                  ElevatedButton(
                                    child: const Text('Save'),
                                    onPressed: () async {
                                      final newName =
                                          nameController.text.trim();
                                      if (newName.isNotEmpty) {
                                        await FirebaseFirestore.instance
                                            .collection('users')
                                            .doc(user.uid)
                                            .set({
                                              'name': newName,
                                            }, SetOptions(merge: true));
                                        Navigator.of(ctx).pop();
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Name set! To change it later, please message your provider.',
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    // Plans first
                    ...planIds.map((planId) => PlanTile(
                      planId: planId,
                      onExerciseCompleted: _onExerciseCompleted,
                    )),
                    // Divider if both present
                    if (planIds.isNotEmpty && exerciseIds.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Divider(thickness: 1),
                      ),
                    // Directly assigned exercises
                    if (exerciseIds.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 4.0,
                        ),
                        child: Text(
                          'Additional Exercises:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepPurple,
                          ),
                        ),
                      ),
                    ...exerciseIds.map((eid) => ExerciseTile(
                      exerciseId: eid,
                      onExerciseCompleted: _onExerciseCompleted,
                    )),
                  ],
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Check if we're in landscape mode (wider than tall)
                      final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
                      
                      if (isLandscape) {
                        // Landscape: Show all buttons in a single row with wrap
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            _buildCompactButton(
                              icon: Icons.add_circle_outline,
                              label: 'Add Pain',
                              onPressed: () async {
                                await _showAddPainLevelDialog(context, user.uid);
                              },
                            ),
                            _buildCompactButton(
                              icon: Icons.history,
                              label: 'Pain History',
                              onPressed: () {
                                _showPainHistoryDialog(context, user.uid);
                              },
                            ),
                            _buildCompactButton(
                              icon: Icons.notifications_active,
                              label: 'Send Nudge',
                              onPressed: () async {
                                final now = DateTime.now();
                                await FirebaseFirestore.instance
                                    .collection('users')
                                    .doc(user.uid)
                                    .set({
                                      'nudge': 1,
                                      'lastNudge': now.toIso8601String(),
                                    }, SetOptions(merge: true));
                                final formattedTime =
                                    '${now.month}/${now.day}/${now.year} at ${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Nudge sent on $formattedTime')),
                                );
                              },
                            ),
                            _buildCompactButton(
                              icon: Icons.message_outlined,
                              label: 'Message',
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (context) => MessagesScreen(user: user),
                                  ),
                                );
                              },
                            ),
                            _buildCompactButton(
                              icon: Icons.notifications_outlined,
                              label: 'Settings',
                              onPressed: () {
                                _showNotificationSettingsDialog(context);
                              },
                            ),
                          ],
                        );
                      } else {
                        // Portrait: Show in rows as before
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Pain tracking buttons
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 400),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      icon: const Icon(Icons.add_circle_outline),
                                      label: const Text(
                                        'Add Pain Level',
                                        textAlign: TextAlign.center,
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                          horizontal: 8,
                                        ),
                                      ),
                                      onPressed: () async {
                                        await _showAddPainLevelDialog(
                                          context,
                                          user.uid,
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      icon: const Icon(Icons.history),
                                      label: const Text(
                                        'View Pain History',
                                        textAlign: TextAlign.center,
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                          horizontal: 8,
                                        ),
                                      ),
                                      onPressed: () {
                                        _showPainHistoryDialog(context, user.uid);
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Communication buttons with independent message input
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 400),
                              child: MessageButtonRow(
                                user: user,
                                getUnreadMessageInfo: _getUnreadMessageInfo,
                                markProviderMessagesAsRead:
                                    _markProviderMessagesAsRead,
                                formatMessageTime: _formatMessageTime,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Notification settings button
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 400),
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.notifications_outlined),
                                label: const Text(
                                  'Exercise Reminder Settings',
                                  textAlign: TextAlign.center,
                                ),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                    horizontal: 16,
                                  ),
                                ),
                                onPressed: () {
                                  _showNotificationSettingsDialog(context);
                                },
                              ),
                            ),
                          ],
                        );
                      }
                    },
                  ),
                ),
              ),
            ],
          );
        },
        ),
      ),
    );
  }
}
