import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_ui_auth/firebase_ui_auth.dart' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TrueBalance Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data;
        if (user != null) {
          // Add user to Firestore users table if not present, but don't overwrite existing planIds or assigned names
          final userRef = FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid);
          userRef.get().then((doc) {
            if (!doc.exists) {
              // Only create new user document if it doesn't exist
              userRef.set({
                'name': user.displayName ?? '',
                'contact': user.email ?? '',
                'contactType': 'email',
                'notes': '',
                'planIds': [],
              });
            } else {
              // User exists, only update contact info without touching planIds or name
              Map<String, dynamic> updateData = {
                'contact': user.email ?? '',
                'contactType': 'email',
              };
              // Only update name if user has a display name and current name is empty
              final currentData = doc.data() ?? {};
              final currentName = currentData['name'] ?? '';
              if (user.displayName != null &&
                  user.displayName!.isNotEmpty &&
                  currentName.isEmpty) {
                updateData['name'] = user.displayName!;
              }
              userRef.set(updateData, SetOptions(merge: true));
            }
          });
        }
        if (!snapshot.hasData) {
          return ui.SignInScreen(providers: [ui.EmailAuthProvider()]);
        }
        return const HomeScreen();
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
    } else if (difference.inMinutes >= 1) {
      return '${difference.inMinutes} minutes';
    } else {
      return 'moments';
    }
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

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Exercise Plans'),
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
      body: StreamBuilder<DocumentSnapshot>(
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
                                  : 'Hi Anonymous User!',
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
                                                    'Name set! To change it later, please message admin.',
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
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 64,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'You have no assigned plans or exercises yet.',
                          style: TextStyle(fontSize: 20, color: Colors.grey),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.notifications_active),
                          label: const Text('Send me a Nudge'),
                          onPressed: () async {
                            final now = DateTime.now();
                            await FirebaseFirestore.instance
                                .collection('users')
                                .doc(user.uid)
                                .set({
                                  'nudge': 1,
                                  'lastNudge': now.toIso8601String(),
                                }, SetOptions(merge: true));
                            // Format timestamp in a user-friendly way
                            final formattedTime =
                                '${now.month}/${now.day}/${now.year} at ${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Nudge sent on $formattedTime'),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        MessageInputWidget(user: user),
                      ],
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
                        future: _getExerciseStatusMessage(user.uid),
                        builder: (context, snapshot) {
                          final greeting =
                              name.isNotEmpty
                                  ? 'Hi $name!'
                                  : 'Hi Anonymous User!';
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
                                              'Name set! To change it later, please message admin.',
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
                    ...planIds.map((planId) => PlanTile(planId: planId)),
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
                    ...exerciseIds.map((eid) => ExerciseTile(exerciseId: eid)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.notifications_active),
                      label: const Text('Send me a Nudge'),
                      onPressed: () async {
                        final now = DateTime.now();
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(user.uid)
                            .set({
                              'nudge': 1,
                              'lastNudge': now.toIso8601String(),
                            }, SetOptions(merge: true));
                        // Format timestamp in a user-friendly way
                        final formattedTime =
                            '${now.month}/${now.day}/${now.year} at ${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Nudge sent on $formattedTime'),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    MessageInputWidget(user: user),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class PlanTile extends StatelessWidget {
  final String planId;
  const PlanTile({super.key, required this.planId});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream:
          FirebaseFirestore.instance
              .collection('plans')
              .doc(planId)
              .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return ListTile(title: const Text('Loading...'));
        final plan = snapshot.data!.data() as Map<String, dynamic>? ?? {};

        // Handle both old and new data structures
        List<Map<String, dynamic>> exerciseData = [];

        // Check for new structure first (exercises array with exerciseId objects)
        if (plan.containsKey('exercises') && plan['exercises'] is List) {
          final exercisesList = List<Map<String, dynamic>>.from(
            (plan['exercises'] as List).map((e) => e as Map<String, dynamic>),
          );

          // Sort by sortOrder if available
          exercisesList.sort((a, b) {
            final aOrder = a['sortOrder'] ?? 0;
            final bOrder = b['sortOrder'] ?? 0;
            return (aOrder as num).compareTo(bOrder as num);
          });

          // Store full exercise data including phase
          exerciseData =
              exercisesList
                  .where((exercise) => exercise['exerciseId'] != null)
                  .toList();
        }
        // Fallback to old structure (simple exerciseIds array)
        else if (plan.containsKey('exerciseIds') &&
            plan['exerciseIds'] is List) {
          final exerciseIds = List<String>.from(plan['exerciseIds'] ?? []);
          exerciseData =
              exerciseIds
                  .map((id) => {'exerciseId': id, 'phase': null})
                  .toList();
        }

        return ExpansionTile(
          title: Text(plan['name'] ?? 'Unnamed Plan'),
          subtitle:
              exerciseData.isEmpty
                  ? const Text(
                    'No exercises found',
                    style: TextStyle(color: Colors.red, fontSize: 12),
                  )
                  : Text(
                    '${exerciseData.length} exercise(s)',
                    style: const TextStyle(fontSize: 12),
                  ),
          children:
              exerciseData
                  .map(
                    (data) => ExerciseTile(
                      exerciseId: data['exerciseId'] as String,
                      phase: data['phase'] as String?,
                    ),
                  )
                  .toList(),
        );
      },
    );
  }
}

class ExerciseTile extends StatelessWidget {
  final String exerciseId;
  final String? phase;
  const ExerciseTile({super.key, required this.exerciseId, this.phase});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream:
          FirebaseFirestore.instance
              .collection('exercises')
              .doc(exerciseId)
              .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return ListTile(title: const Text('Loading...'));
        final exercise = snapshot.data!.data() as Map<String, dynamic>? ?? {};
        final title = exercise['title'] ?? 'Unnamed Exercise';
        final description = exercise['description'];
        final recommendedReps = exercise['recommendedRepetitions'];
        final videoUrl = exercise['videoUrl'];
        final createdAt = exercise['createdAt'];
        final updatedAt = exercise['updatedAt'];

        // Build subtitle with available info
        List<String> subtitleParts = [];
        if (recommendedReps != null && recommendedReps.toString().isNotEmpty) {
          subtitleParts.add('Reps: $recommendedReps');
        }
        if (description != null && description.toString().isNotEmpty) {
          // Show first 50 characters of description
          String shortDesc = description.toString();
          if (shortDesc.length > 50) {
            shortDesc = '${shortDesc.substring(0, 50)}...';
          }
          subtitleParts.add(shortDesc);
        }

        return ExpansionTile(
          title:
              phase != null
                  ? RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: title,
                          style: DefaultTextStyle.of(context).style,
                        ),
                        TextSpan(
                          text: ' - ',
                          style: DefaultTextStyle.of(
                            context,
                          ).style.copyWith(color: Colors.grey),
                        ),
                        TextSpan(
                          text: phase,
                          style: DefaultTextStyle.of(
                            context,
                          ).style.copyWith(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                  : Text(title),
          subtitle:
              subtitleParts.isNotEmpty
                  ? Text(
                    subtitleParts.join(' • '),
                    style: const TextStyle(fontSize: 12),
                  )
                  : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Last check-in display and Did it button
              StreamBuilder<QuerySnapshot>(
                stream:
                    FirebaseFirestore.instance
                        .collection('exercise_check_ins')
                        .where(
                          'userId',
                          isEqualTo: FirebaseAuth.instance.currentUser?.uid,
                        )
                        .where('exerciseId', isEqualTo: exerciseId)
                        .snapshots(),
                builder: (context, snapshot) {
                  DateTime? lastCheckIn;
                  bool doneToday = false;

                  if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
                    // Sort by timestamp descending to get the latest
                    final docs = snapshot.data!.docs;
                    docs.sort((a, b) {
                      final aData = a.data() as Map<String, dynamic>;
                      final bData = b.data() as Map<String, dynamic>;
                      final aTs = aData['timestamp'];
                      final bTs = bData['timestamp'];

                      DateTime? aDt, bDt;
                      if (aTs is Timestamp) aDt = aTs.toDate();
                      if (bTs is Timestamp) bDt = bTs.toDate();

                      if (aDt == null && bDt == null) return 0;
                      if (aDt == null) return 1;
                      if (bDt == null) return -1;
                      return bDt.compareTo(aDt);
                    });

                    final latestDoc = docs.first;
                    final latestData = latestDoc.data() as Map<String, dynamic>;
                    final timestamp = latestData['timestamp'];

                    if (timestamp is Timestamp) {
                      lastCheckIn = timestamp.toDate();
                    }

                    // Check if done today
                    if (lastCheckIn != null) {
                      final now = DateTime.now();
                      doneToday =
                          lastCheckIn.year == now.year &&
                          lastCheckIn.month == now.month &&
                          lastCheckIn.day == now.day;
                    }
                  }

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Last check-in display
                      if (lastCheckIn != null) ...[
                        Text(
                          doneToday
                              ? 'Last Done: Today!'
                              : 'Last: ${lastCheckIn.month}/${lastCheckIn.day} ${lastCheckIn.hour.toString().padLeft(2, '0')}:${lastCheckIn.minute.toString().padLeft(2, '0')}',
                          style: TextStyle(
                            fontSize: 10,
                            color: doneToday ? Colors.grey : Colors.green,
                            fontWeight:
                                doneToday ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // Did it button
                      ElevatedButton(
                        onPressed: () async {
                          final user = FirebaseAuth.instance.currentUser;
                          if (user != null) {
                            await FirebaseFirestore.instance
                                .collection('exercise_check_ins')
                                .add({
                                  'userId': user.uid,
                                  'exerciseId': exerciseId,
                                  'timestamp': FieldValue.serverTimestamp(),
                                });
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              doneToday ? Colors.grey : Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          minimumSize: const Size(60, 30),
                        ),
                        child: Text(
                          'Did it!',
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle:
                                doneToday ? FontStyle.italic : FontStyle.normal,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.expand_more),
                    ],
                  );
                },
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (description != null &&
                      description.toString().isNotEmpty) ...[
                    const Text(
                      'Description:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description.toString(),
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (recommendedReps != null &&
                      recommendedReps.toString().isNotEmpty) ...[
                    Row(
                      children: [
                        const Text(
                          'Recommended Repetitions: ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          recommendedReps.toString(),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (videoUrl != null && videoUrl.toString().isNotEmpty) ...[
                    Row(
                      children: [
                        const Text(
                          'Video URL: ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            videoUrl.toString(),
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.blue,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (createdAt != null && createdAt.toString().isNotEmpty) ...[
                    Row(
                      children: [
                        const Text(
                          'Created: ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                        Text(
                          _formatDate(createdAt.toString()),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (updatedAt != null && updatedAt.toString().isNotEmpty) ...[
                    Row(
                      children: [
                        const Text(
                          'Updated: ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                        Text(
                          _formatDate(updatedAt.toString()),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _formatDate(String dateString) {
    try {
      final date = DateTime.parse(dateString);
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } catch (e) {
      return dateString;
    }
  }
}

// MessageInputWidget for user message input
class MessageInputWidget extends StatefulWidget {
  final User user;
  const MessageInputWidget({super.key, required this.user});
  @override
  State<MessageInputWidget> createState() => _MessageInputWidgetState();
}

class _MessageInputWidgetState extends State<MessageInputWidget> {
  bool showInput = false;
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reset() {
    _controller.clear();
    setState(() {
      showInput = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> children = [];
    if (!showInput) {
      children.add(
        ElevatedButton.icon(
          icon: const Icon(Icons.message),
          label: const Text('Send me a message'),
          onPressed: () {
            setState(() {
              showInput = true;
            });
          },
        ),
      );
    }
    if (showInput) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: 'Type your message',
                  border: OutlineInputBorder(),
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    child: const Text('Send'),
                    onPressed: () async {
                      final text = _controller.text.trim();
                      final now = DateTime.now();
                      if (text.isNotEmpty) {
                        await FirebaseFirestore.instance
                            .collection('messages')
                            .add({
                              'userId': widget.user.uid,
                              'timestamp': now.toIso8601String(),
                              'message': text,
                            });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Message sent!')),
                        );
                      } else {
                        // Blank message is a nudge
                        await FirebaseFirestore.instance
                            .collection('messages')
                            .add({
                              'userId': widget.user.uid,
                              'timestamp': now.toIso8601String(),
                              'message': '',
                            });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Nudge sent!')),
                        );
                      }
                      // Set nudge in users table for both cases
                      await FirebaseFirestore.instance
                          .collection('users')
                          .doc(widget.user.uid)
                          .set({
                            'nudge': 1,
                            'lastNudge': now.toIso8601String(),
                          }, SetOptions(merge: true));
                      _reset();
                    },
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton(
                    child: const Text('Cancel'),
                    onPressed: _reset,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Message History:',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 300, // Fixed height instead of Expanded
                child: StreamBuilder<QuerySnapshot>(
                  stream:
                      FirebaseFirestore.instance
                          .collection('messages')
                          .where('userId', isEqualTo: widget.user.uid)
                          .orderBy('timestamp', descending: true)
                          .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      // If Firestore index error, fallback to unordered
                      return StreamBuilder<QuerySnapshot>(
                        stream:
                            FirebaseFirestore.instance
                                .collection('messages')
                                .where('userId', isEqualTo: widget.user.uid)
                                .snapshots(),
                        builder: (context, snap2) {
                          if (snap2.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (!snap2.hasData) {
                            return const Text('No messages found.');
                          }
                          final docs =
                              snap2.data!.docs
                                  .where(
                                    (d) =>
                                        (d.data()
                                            as Map<
                                              String,
                                              dynamic
                                            >?)?['timestamp'] !=
                                        null,
                                  )
                                  .toList();
                          if (docs.isEmpty) {
                            return const Text('No messages sent yet.');
                          }
                          docs.sort((a, b) {
                            dynamic ta =
                                (a.data() as Map<String, dynamic>)['timestamp'];
                            dynamic tb =
                                (b.data() as Map<String, dynamic>)['timestamp'];
                            DateTime? dta;
                            DateTime? dtb;
                            if (ta is Timestamp) {
                              dta = ta.toDate();
                            } else if (ta is String) {
                              try {
                                dta = DateTime.parse(ta);
                              } catch (_) {}
                            }
                            if (tb is Timestamp) {
                              dtb = tb.toDate();
                            } else if (tb is String) {
                              try {
                                dtb = DateTime.parse(tb);
                              } catch (_) {}
                            }
                            if (dtb == null && dta == null) return 0;
                            if (dtb == null) return -1;
                            if (dta == null) return 1;
                            return dtb.compareTo(dta);
                          });
                          return ListView.builder(
                            itemCount: docs.length,
                            itemBuilder: (context, idx) {
                              final data =
                                  docs[idx].data() as Map<String, dynamic>? ??
                                  {};
                              final msg = data['message'] ?? '';
                              final ts = data['timestamp'] ?? '';
                              // Robustly parse fromAdmin field
                              bool fromAdmin = false;
                              if (data.containsKey('fromAdmin')) {
                                final raw = data['fromAdmin'];
                                if (raw is bool) {
                                  fromAdmin = raw;
                                } else if (raw is String) {
                                  fromAdmin = raw.toLowerCase() == 'true';
                                } else if (raw is int) {
                                  fromAdmin = raw == 1;
                                }
                              }
                              DateTime? dt;
                              if (ts is Timestamp) {
                                dt = ts.toDate();
                              } else if (ts is String) {
                                try {
                                  dt = DateTime.parse(ts);
                                } catch (_) {}
                              }
                              final formatted =
                                  dt != null
                                      ? '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
                                      : ts.toString();
                              if (fromAdmin) {
                                // Admin message: left-aligned, blue background
                                return Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 2,
                                      horizontal: 8,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.blue[50],
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.blue,
                                        width: 0.5,
                                      ),
                                    ),
                                    child: RichText(
                                      text: TextSpan(
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Colors.black,
                                        ),
                                        children: [
                                          TextSpan(
                                            text: msg.isEmpty ? '(nudge)' : msg,
                                          ),
                                          TextSpan(
                                            text:
                                                ' sent by Admin at $formatted',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.blue,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              } else {
                                // User message: right-aligned, purple background
                                return Align(
                                  alignment: Alignment.centerRight,
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 2,
                                      horizontal: 8,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.deepPurple[50],
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.deepPurple,
                                        width: 0.5,
                                      ),
                                    ),
                                    child: RichText(
                                      text: TextSpan(
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Colors.black,
                                        ),
                                        children: [
                                          TextSpan(
                                            text: msg.isEmpty ? '(nudge)' : msg,
                                          ),
                                          TextSpan(
                                            text: ' sent by You at $formatted',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.deepPurple,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }
                            },
                          );
                        },
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Text('No messages found.');
                    }
                    final docs = snapshot.data!.docs;
                    if (docs.isEmpty) {
                      return const Text('No messages sent yet.');
                    }
                    return ListView.builder(
                      itemCount: docs.length,
                      itemBuilder: (context, idx) {
                        final data =
                            docs[idx].data() as Map<String, dynamic>? ?? {};
                        final msg = data['message'] ?? '';
                        final ts = data['timestamp'] ?? '';
                        // Robustly parse fromAdmin field
                        bool fromAdmin = false;
                        if (data.containsKey('fromAdmin')) {
                          final raw = data['fromAdmin'];
                          if (raw is bool) {
                            fromAdmin = raw;
                          } else if (raw is String) {
                            fromAdmin = raw.toLowerCase() == 'true';
                          } else if (raw is int) {
                            fromAdmin = raw == 1;
                          }
                        }
                        DateTime? dt;
                        if (ts is Timestamp) {
                          dt = ts.toDate();
                        } else if (ts is String) {
                          try {
                            dt = DateTime.parse(ts);
                          } catch (_) {}
                        }
                        final formatted =
                            dt != null
                                ? '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
                                : ts.toString();
                        if (fromAdmin) {
                          // Admin message: left-aligned, blue background
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                vertical: 2,
                                horizontal: 8,
                              ),
                              padding: const EdgeInsets.symmetric(
                                vertical: 6,
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue[50],
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.blue,
                                  width: 0.5,
                                ),
                              ),
                              child: RichText(
                                text: TextSpan(
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.black,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: msg.isEmpty ? '(nudge)' : msg,
                                    ),
                                    TextSpan(
                                      text: ', sent by Admin at $formatted',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.blue,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        } else {
                          // User message: right-aligned, purple background
                          return Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                vertical: 2,
                                horizontal: 8,
                              ),
                              padding: const EdgeInsets.symmetric(
                                vertical: 6,
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.deepPurple[50],
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.deepPurple,
                                  width: 0.5,
                                ),
                              ),
                              child: RichText(
                                text: TextSpan(
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.black,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: msg.isEmpty ? '(nudge)' : msg,
                                    ),
                                    TextSpan(
                                      text: ', sent by You at $formatted',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.deepPurple,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(children: children);
  }
}
