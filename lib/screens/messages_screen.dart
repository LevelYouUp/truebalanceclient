import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class MessagesScreen extends StatefulWidget {
  final User user;

  const MessagesScreen({super.key, required this.user});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Mark messages as read when screen opens
    _markProviderMessagesAsRead();
  }

  Future<void> _markProviderMessagesAsRead() async {
    try {
      final messagesQuery = await FirebaseFirestore.instance
          .collection('messages')
          .where('userId', isEqualTo: widget.user.uid)
          .where('fromAdmin', isEqualTo: true)
          .get();

      final batch = FirebaseFirestore.instance.batch();

      for (var doc in messagesQuery.docs) {
        final data = doc.data();
        if (!data.containsKey('read') || data['read'] != true) {
          batch.update(doc.reference, {'read': true});
        }
      }

      await batch.commit();
    } catch (e) {
      // Handle error silently
    }
  }

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

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    final now = DateTime.now();

    if (text.isNotEmpty) {
      await FirebaseFirestore.instance.collection('messages').add({
        'userId': widget.user.uid,
        'timestamp': now.toIso8601String(),
        'message': text,
      });

      // Also send nudge notification
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.user.uid)
          .set({
        'nudge': 1,
        'lastNudge': now.toIso8601String(),
      }, SetOptions(merge: true));

      _controller.clear();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message sent!'),
            duration: Duration(seconds: 1),
          ),
        );
        
        // Navigate back to main page after sending to discourage multiple messages
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Message history - takes up remaining space
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('messages')
                  .where('userId', isEqualTo: widget.user.uid)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                // Sort messages by timestamp in memory
                final messages = snapshot.data!.docs.toList();
                messages.sort((a, b) {
                  final aData = a.data() as Map<String, dynamic>;
                  final bData = b.data() as Map<String, dynamic>;
                  
                  final aTimestamp = aData['timestamp'];
                  final bTimestamp = bData['timestamp'];
                  
                  DateTime? aTime;
                  DateTime? bTime;
                  
                  if (aTimestamp is Timestamp) {
                    aTime = aTimestamp.toDate();
                  } else if (aTimestamp is String) {
                    try {
                      aTime = DateTime.parse(aTimestamp);
                    } catch (_) {}
                  }
                  
                  if (bTimestamp is Timestamp) {
                    bTime = bTimestamp.toDate();
                  } else if (bTimestamp is String) {
                    try {
                      bTime = DateTime.parse(bTimestamp);
                    } catch (_) {}
                  }
                  
                  if (aTime == null || bTime == null) return 0;
                  return bTime.compareTo(aTime); // Descending order
                });

                if (messages.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.message_outlined,
                            size: 64,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No messages yet',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Send a message to your provider to get started',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final messageData =
                        messages[index].data() as Map<String, dynamic>;
                    final message = messageData['message'] ?? '';
                    final fromAdmin = messageData['fromAdmin'] ?? false;
                    final timestamp = messageData['timestamp'];

                    DateTime? messageTime;
                    if (timestamp is Timestamp) {
                      messageTime = timestamp.toDate();
                    } else if (timestamp is String) {
                      try {
                        messageTime = DateTime.parse(timestamp);
                      } catch (_) {}
                    }

                    final timeText = messageTime != null
                        ? _formatMessageTime(messageTime)
                        : '';

                    final isUserMessage = !fromAdmin;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        mainAxisAlignment: isUserMessage
                            ? MainAxisAlignment.end
                            : MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!isUserMessage) ...[
                            CircleAvatar(
                              backgroundColor: Colors.deepPurple.shade100,
                              radius: 20,
                              child: Icon(
                                Icons.medical_services,
                                color: Colors.deepPurple,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: isUserMessage
                                    ? Colors.deepPurple
                                    : Colors.grey.shade200,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: Radius.circular(
                                    isUserMessage ? 16 : 4,
                                  ),
                                  bottomRight: Radius.circular(
                                    isUserMessage ? 4 : 16,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: isUserMessage
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  if (!isUserMessage)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 4),
                                      child: Text(
                                        'Provider',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.deepPurple,
                                        ),
                                      ),
                                    ),
                                  if (message.isNotEmpty)
                                    Text(
                                      message,
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: isUserMessage
                                            ? Colors.white
                                            : Colors.black87,
                                      ),
                                    )
                                  else
                                    Text(
                                      '👋 Nudge sent',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontStyle: FontStyle.italic,
                                        color: isUserMessage
                                            ? Colors.white70
                                            : Colors.black54,
                                      ),
                                    ),
                                  if (timeText.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        timeText,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isUserMessage
                                              ? Colors.white70
                                              : Colors.grey.shade600,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (isUserMessage) ...[
                            const SizedBox(width: 8),
                            CircleAvatar(
                              backgroundColor: Colors.deepPurple.shade700,
                              radius: 20,
                              child: Icon(
                                Icons.person,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // Message input area - fixed at bottom
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.shade300,
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: InputDecoration(
                          hintText: 'Type your message...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: const BorderSide(
                              color: Colors.deepPurple,
                              width: 2,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                        ),
                        maxLines: 4,
                        minLines: 1,
                        textCapitalization: TextCapitalization.sentences,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FloatingActionButton(
                      onPressed: _sendMessage,
                      backgroundColor: Colors.deepPurple,
                      child: const Icon(Icons.send, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
