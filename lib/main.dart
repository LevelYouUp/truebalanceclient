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
          if (planIds.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.info_outline, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'You have no assigned plans yet.',
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Nudge sent at ${now.toLocal()}'),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  MessageInputWidget(user: user),
                ],
              ),
            );
          }
          return Column(
            children: [
              Expanded(
                child: ListView(
                  children:
                      planIds
                          .map((planId) => PlanTile(planId: planId))
                          .toList(),
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Nudge sent at ${now.toLocal()}'),
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
        List<String> exerciseIds = [];

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

          // Extract exerciseIds from the sorted list
          exerciseIds =
              exercisesList
                  .map((exercise) => exercise['exerciseId'] as String?)
                  .where((id) => id != null)
                  .cast<String>()
                  .toList();
        }
        // Fallback to old structure (simple exerciseIds array)
        else if (plan.containsKey('exerciseIds') &&
            plan['exerciseIds'] is List) {
          exerciseIds = List<String>.from(plan['exerciseIds'] ?? []);
        }

        // Debug logging to help identify the issue
        print('Plan data: $plan');
        print('Exercise IDs found: $exerciseIds');

        return ExpansionTile(
          title: Text(plan['name'] ?? 'Unnamed Plan'),
          subtitle:
              exerciseIds.isEmpty
                  ? const Text(
                    'No exercises found',
                    style: TextStyle(color: Colors.red, fontSize: 12),
                  )
                  : Text(
                    '${exerciseIds.length} exercise(s)',
                    style: const TextStyle(fontSize: 12),
                  ),
          children:
              exerciseIds.map((id) => ExerciseTile(exerciseId: id)).toList(),
        );
      },
    );
  }
}

class ExerciseTile extends StatelessWidget {
  final String exerciseId;
  const ExerciseTile({super.key, required this.exerciseId});
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
          title: Text(title),
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
