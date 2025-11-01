import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:convert';
import 'firebase_options.dart';
import 'exercise_video_player.dart';
import 'exercise_reminder_manager.dart';

// Simple passcode validation service using encrypted passcode comparison
class PasscodeService {
  // Decryption method for encrypted passcodes
  static String decryptPasscode(String encryptedPasscode) {
    try {
      const String encryptionKey = 'TrueBalanceAdmin2024SecureKey!@#';
      final keyBytes = utf8.encode(encryptionKey);
      final encryptedBytes = base64Decode(encryptedPasscode);
      final decrypted = <int>[];

      for (int i = 0; i < encryptedBytes.length; i++) {
        decrypted.add(encryptedBytes[i] ^ keyBytes[i % keyBytes.length]);
      }

      return utf8.decode(decrypted);
    } catch (e) {
      return '';
    }
  }

  static Future<Map<String, dynamic>> validatePasscodeHash(
    String passcode,
  ) async {
    try {
      final normalizedPasscode = passcode.trim().toUpperCase();

      if (normalizedPasscode.isEmpty) {
        return {
          'isValid': false,
          'error': 'Please enter your provider passcode',
        };
      }

      // Query users collection for provider users with encrypted passcodes
      final providerQuery =
          await FirebaseFirestore.instance
              .collection('users')
              .where('isAdmin', isEqualTo: true)
              .where('active', isEqualTo: true)
              .get();

      print(
        'Debug: Found ${providerQuery.docs.length} active provider user(s)',
      );

      if (providerQuery.docs.isEmpty) {
        return {'isValid': false, 'error': 'No active providers found.'};
      }

      // Check each provider's encrypted passcode
      for (var providerDoc in providerQuery.docs) {
        final providerData = providerDoc.data();
        print(
          'Debug: Checking provider ${providerDoc.id}, name: ${providerData['name'] ?? 'no name'}, contact: ${providerData['contact'] ?? 'no contact'}',
        );

        final encryptedPasscode =
            providerData['registrationPasscodeHash'] as String?;

        print(
          'Debug: Provider ${providerDoc.id} has passcode hash: ${encryptedPasscode != null ? 'yes' : 'no'}',
        );

        if (encryptedPasscode != null) {
          final decryptedPasscode = decryptPasscode(encryptedPasscode);
          final normalizedDecrypted = decryptedPasscode.trim().toUpperCase();

          print(
            'Debug: Comparing "${normalizedDecrypted}" with "${normalizedPasscode}"',
          );

          if (normalizedDecrypted == normalizedPasscode) {
            return {
              'isValid': true,
              'providerId': providerDoc.id,
              'providerName': providerData['name'] ?? 'Unknown Provider',
            };
          }
        }
      }

      return {'isValid': false, 'error': 'Invalid provider passcode'};
    } catch (e) {
      return {
        'isValid': false,
        'error': 'Error validating passcode: ${e.toString()}',
      };
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize notification system
  await ExerciseReminderManager.initialize();

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

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? _errorMessage;

  // Helper method to check if user account is active and has provider verification
  Future<Map<String, dynamic>> _checkUserActiveStatus(String userId) async {
    try {
      // Try to get the document, with a retry for newly registered users
      DocumentSnapshot? userDoc;
      for (int attempt = 1; attempt <= 3; attempt++) {
        userDoc =
            await FirebaseFirestore.instance
                .collection('users')
                .doc(userId)
                .get();

        if (userDoc.exists) {
          break; // Document found, exit retry loop
        }

        if (attempt < 3) {
          // Wait a bit before retrying, in case document is still being created
          await Future.delayed(Duration(milliseconds: 200 * attempt));
        }
      }

      if (!userDoc!.exists) {
        // For newly registered users, the document might not exist yet
        // Treat this as requiring provider verification
        return {'isActive': false, 'reason': 'Provider verification required'};
      }

      final userData = userDoc.data() as Map<String, dynamic>? ?? {};

      // Check active flag (default to true if not set for backward compatibility)
      final isActive = userData['active'] ?? true;

      if (!isActive) {
        // Check if user has already provided passcode and is linked to provider
        final activatedBy = userData['activatedBy'];
        if (activatedBy != null && activatedBy.toString().trim().isNotEmpty) {
          // User has provided passcode but provider hasn't activated them yet
          return {'isActive': false, 'reason': 'Pending provider activation'};
        } else {
          // User account is inactive and no passcode provided - they need to enter passcode first
          return {
            'isActive': false,
            'reason': 'Provider verification required',
          };
        }
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

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        final user = snapshot.data;

        if (user != null) {
          // Check if user account is active before proceeding
          return FutureBuilder<Map<String, dynamic>>(
            future: _checkUserActiveStatus(user.uid),
            builder: (context, activeSnapshot) {
              if (activeSnapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }

              final activeStatus =
                  activeSnapshot.data ??
                  {'isActive': false, 'reason': 'Unknown error'};

              if (!activeStatus['isActive']) {
                // Account is not active - show inactive user page instead of logging out
                return InactiveUserPage(reason: activeStatus['reason']);
              }

              // User is active, proceed with normal user setup
              final userRef = FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid);
              userRef.get().then((doc) {
                final now = DateTime.now();
                if (!doc.exists) {
                  // Only create new user document if it doesn't exist
                  // Note: New users created through registration will have providerId set
                  userRef.set({
                    'name': user.displayName ?? '',
                    'contact': user.email ?? '',
                    'contactType': 'email',
                    'notes': '',
                    'planIds': [],
                    'active':
                        false, // Default to inactive - provider must approve
                    'providerId': '', // Will be set during registration
                    'firstLoginTime': now.toIso8601String(),
                    'lastLoginTime': now.toIso8601String(),
                  });
                } else {
                  // User exists, update contact info and lastLoginTime
                  Map<String, dynamic> updateData = {
                    'contact': user.email ?? '',
                    'contactType': 'email',
                    'lastLoginTime': now.toIso8601String(),
                  };
                  // Only update name if user has a display name and current name is empty
                  final currentData = doc.data() ?? {};
                  final currentName = currentData['name'] ?? '';
                  if (user.displayName != null &&
                      user.displayName!.isNotEmpty &&
                      currentName.isEmpty) {
                    updateData['name'] = user.displayName!;
                  }
                  // Ensure firstLoginTime exists (for existing users who don't have it yet)
                  if (!currentData.containsKey('firstLoginTime') ||
                      currentData['firstLoginTime'] == null) {
                    updateData['firstLoginTime'] = now.toIso8601String();
                  }
                  // Ensure active field exists (for existing users who don't have it yet)
                  if (!currentData.containsKey('active')) {
                    updateData['active'] =
                        true; // Default to active for existing users
                  }
                  // Ensure providerId field exists (for existing users who don't have it yet)
                  if (!currentData.containsKey('providerId')) {
                    updateData['providerId'] = ''; // Empty for legacy users
                  }
                  userRef.set(updateData, SetOptions(merge: true));
                }
              });

              return const HomeScreen();
            },
          );
        }

        // User is not logged in - show login screen
        if (!snapshot.hasData) {
          return _buildLoginScreen();
        }

        return const HomeScreen();
      },
    );
  }

  Widget _buildLoginScreen() {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Logo
                    Center(
                      child: Image.asset(
                        'assets/images/TRUEBALANCE-PAINRELIEF_LOGO_DARK_2256x504.png',
                        height: 100,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return const Text(
                            'TrueBalance Client',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.deepPurple,
                            ),
                            textAlign: TextAlign.center,
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Welcome text
                    const Text(
                      'Welcome Back',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: Colors.deepPurple,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Sign in to continue',
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),

                    // Error message if present
                    if (_errorMessage != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        margin: const EdgeInsets.only(bottom: 24),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          border: Border.all(color: Colors.red.shade300),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.red.shade700,
                              size: 24,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.close,
                                color: Colors.red.shade700,
                                size: 20,
                              ),
                              onPressed: () {
                                setState(() {
                                  _errorMessage = null;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Login form
                    const _LoginForm(),

                    const SizedBox(height: 16),

                    // Registration link
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Don\'t have an account? ',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 14,
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder:
                                    (context) => const RegistrationScreen(),
                              ),
                            );
                          },
                          child: const Text(
                            'Register here',
                            style: TextStyle(
                              color: Colors.deepPurple,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class InactiveUserPage extends StatefulWidget {
  final String reason;

  const InactiveUserPage({super.key, required this.reason});

  @override
  State<InactiveUserPage> createState() => _InactiveUserPageState();
}

class _InactiveUserPageState extends State<InactiveUserPage> {
  Timer? _activationCheckTimer;
  bool _isChecking = false;
  final _passcodeController = TextEditingController();
  bool _isValidatingPasscode = false;
  bool _showPasscodeSection = false;
  bool _hasProvidedPasscode = false;

  @override
  void initState() {
    super.initState();
    // Only show passcode section by default for users who need provider verification
    // NOT for users who are already pending provider activation
    _showPasscodeSection = widget.reason == 'Provider verification required';
    _checkInitialPasscodeStatus();
    _startActivationCheck();
  }

  @override
  void dispose() {
    _activationCheckTimer?.cancel();
    _passcodeController.dispose();
    super.dispose();
  }

  Future<void> _checkInitialPasscodeStatus() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        // Try to get the document, with a brief retry for newly registered users
        DocumentSnapshot? userDoc;
        for (int attempt = 1; attempt <= 2; attempt++) {
          userDoc =
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .get();

          if (userDoc.exists) {
            break; // Document found, exit retry loop
          }

          if (attempt < 2) {
            // Wait a bit before retrying
            await Future.delayed(Duration(milliseconds: 300));
          }
        }

        if (userDoc!.exists) {
          final userData = userDoc.data() as Map<String, dynamic>? ?? {};
          final activatedBy = userData['activatedBy'];
          final hasProvidedPasscode =
              activatedBy != null && activatedBy.toString().trim().isNotEmpty;

          setState(() {
            _hasProvidedPasscode = hasProvidedPasscode;
            if (hasProvidedPasscode) {
              _showPasscodeSection =
                  false; // Hide passcode section if already provided
            }
          });
        }
        // If document doesn't exist, keep default values (_hasProvidedPasscode = false)
      }
    } catch (e) {
      // Handle error gracefully - keep default state
      print('Error checking initial passcode status: $e');
    }
  }

  void _startActivationCheck() {
    // Check immediately, then every 10 seconds
    _checkActivationStatus();
    _activationCheckTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkActivationStatus(),
    );
  }

  Future<void> _validateProviderPasscode() async {
    if (_passcodeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter a registration passcode'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isValidatingPasscode = true;
    });

    // Temporarily stop the activation check timer to prevent conflicts
    _activationCheckTimer?.cancel();

    try {
      final result = await PasscodeService.validatePasscodeHash(
        _passcodeController.text,
      );

      if (mounted) {
        if (result['isValid']) {
          // Valid passcode - link the user to the provider (DO NOT ACTIVATE)
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
              'lastUpdated': FieldValue.serverTimestamp(),
              'activatedBy': result['providerId'],
              // NOTE: We do NOT set 'activatedAt' here - that should only be set when admin actually activates the user
              // NOTE: We do NOT set 'active': true here - user remains inactive until provider manually activates them
            });

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Registration passcode verified! You are now linked to ${result['providerName']}. Your account is still pending manual activation by the provider.',
                ),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 4),
              ),
            );

            // Do NOT redirect to AuthGate since user is still inactive
            // Just clear the passcode field and hide the section
            _passcodeController.clear();
            setState(() {
              _showPasscodeSection = false;
            });

            // Restart the activation check timer after a brief delay
            Future.delayed(Duration(seconds: 2), () {
              if (mounted) {
                _startActivationCheck();
              }
            });
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result['error']),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );

          // Restart the activation check timer
          _startActivationCheck();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error validating passcode: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );

        // Restart the activation check timer
        _startActivationCheck();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isValidatingPasscode = false;
        });
      }
    }
  }

  Future<void> _checkActivationStatus() async {
    if (_isChecking || !mounted) return;

    setState(() {
      _isChecking = true;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final userDoc =
            await FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .get();

        if (userDoc.exists) {
          final userData = userDoc.data() ?? {};

          // Check if user has already provided a passcode (has activatedBy field)
          final activatedBy = userData['activatedBy'];
          final hasProvidedPasscode =
              activatedBy != null && activatedBy.toString().trim().isNotEmpty;

          if (hasProvidedPasscode != _hasProvidedPasscode) {
            setState(() {
              _hasProvidedPasscode = hasProvidedPasscode;
              if (hasProvidedPasscode) {
                _showPasscodeSection =
                    false; // Hide passcode section if already provided
              }
            });
          }

          // Check active flag
          final isActive = userData['active'] ?? true;
          bool accountIsActive = isActive;

          // Check activeUntilTime if it exists
          if (accountIsActive) {
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

              if (expirationTime != null &&
                  DateTime.now().isAfter(expirationTime)) {
                accountIsActive = false;
              }
            }
          }

          // Check provider verification - even if account is active,
          // require provider passcode if not yet verified
          // UNLESS the user is a provider themselves (isAdmin: true)
          bool hasProviderVerification = true;
          if (accountIsActive) {
            final activatedBy = userData['activatedBy'];
            if (activatedBy == null || activatedBy.toString().trim().isEmpty) {
              // Check if user is a provider - if so, they don't need external verification
              final isAdmin = userData['isAdmin'] ?? false;
              if (!isAdmin) {
                hasProviderVerification = false;
              }
              // Provider users are considered self-verified
            }
          }

          if (accountIsActive && hasProviderVerification && mounted) {
            // Account is now active and verified, redirect to AuthGate
            _activationCheckTimer?.cancel();
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const AuthGate()),
              (route) => false,
            );
            return;
          }
        }
      }
    } catch (e) {
      // Handle Firestore errors gracefully
      print('Error checking activation status: $e');
      // If it's a Firestore internal error, wait a bit longer before next check
      if (e.toString().contains('FIRESTORE') ||
          e.toString().contains('INTERNAL ASSERTION FAILED')) {
        // Cancel current timer and restart with longer interval
        _activationCheckTimer?.cancel();
        if (mounted) {
          _activationCheckTimer = Timer.periodic(
            const Duration(seconds: 30), // Use longer interval after errors
            (_) => _checkActivationStatus(),
          );
        }
      }
    }

    if (mounted) {
      setState(() {
        _isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Logo
                    Image.asset(
                      'assets/images/TRUEBALANCE-PAINRELIEF_LOGO_DARK_2256x504.png',
                      height: 80,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return const Text(
                          'TrueBalance Client',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepPurple,
                          ),
                          textAlign: TextAlign.center,
                        );
                      },
                    ),
                    const SizedBox(height: 32),

                    // Warning icon
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(50),
                      ),
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 48,
                        color: Colors.orange.shade700,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Title
                    Text(
                      widget.reason == 'Provider verification required'
                          ? 'Provider Verification Required'
                          : widget.reason == 'Pending provider activation'
                          ? 'Pending Provider Activation'
                          : 'Account Not Active',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),

                    // Message
                    Text(
                      widget.reason == 'Provider verification required'
                          ? 'Your account needs provider verification to continue. If you have a registration passcode, you can enter it below to link your account to a provider.'
                          : widget.reason == 'Pending provider activation'
                          ? 'Your registration passcode has been verified and you are linked to a provider. Your account is now pending manual activation by your provider.'
                          : 'Oh no! Your account is not active at this time. If you believe this is an error please reach out to your provider directly.',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey.shade700,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),

                    // Technical reason (if different from user message)
                    if (widget.reason != 'Account marked as inactive' &&
                        widget.reason != 'Account expired' &&
                        widget.reason != 'Pending provider activation') ...[
                      Text(
                        'Technical details: ${widget.reason}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                    ] else ...[
                      const SizedBox(height: 24),
                    ],

                    // Status information
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        border: Border.all(color: Colors.blue.shade200),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          _isChecking
                              ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.blue.shade600,
                                  ),
                                ),
                              )
                              : Icon(
                                Icons.autorenew,
                                color: Colors.blue.shade600,
                                size: 20,
                              ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _isChecking
                                  ? 'Checking account status...'
                                  : widget.reason ==
                                      'Provider verification required'
                                  ? 'Automatically checking for verification every 10 seconds'
                                  : widget.reason ==
                                      'Pending provider activation'
                                  ? 'Automatically checking for provider activation every 10 seconds'
                                  : 'Automatically checking for account activation every 10 seconds',
                              style: TextStyle(
                                color: Colors.blue.shade700,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Action buttons
                    Column(
                      children: [
                        // Registration Passcode Section (for provider verification required)
                        if (widget.reason ==
                            'Provider verification required') ...[
                          if (_showPasscodeSection) ...[
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                border: Border.all(
                                  color: Colors.green.shade200,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'Enter Registration Passcode',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.green.shade800,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Enter the registration passcode provided by your provider to complete account verification',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.green.shade700,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _passcodeController,
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted:
                                        (_) => _validateProviderPasscode(),
                                    decoration: InputDecoration(
                                      labelText: 'Registration Passcode',
                                      hintText: 'Enter registration passcode',
                                      prefixIcon: const Icon(
                                        Icons.verified_user,
                                      ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(
                                          color: Colors.green.shade600,
                                        ),
                                      ),
                                    ),
                                    obscureText: true,
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    height: 40,
                                    child: ElevatedButton(
                                      onPressed:
                                          _isValidatingPasscode
                                              ? null
                                              : _validateProviderPasscode,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green.shade600,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                      child:
                                          _isValidatingPasscode
                                              ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                        Color
                                                      >(Colors.white),
                                                ),
                                              )
                                              : const Text('Verify Passcode'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],

                          // Toggle passcode section button (only show if user hasn't provided passcode yet)
                          if (!_hasProvidedPasscode)
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _showPasscodeSection =
                                        !_showPasscodeSection;
                                  });
                                },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.green.shade700,
                                  side: BorderSide(
                                    color: Colors.green.shade400,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: Icon(
                                  _showPasscodeSection
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                ),
                                label: Text(
                                  _showPasscodeSection
                                      ? 'Hide Passcode Entry'
                                      : 'I have a Registration Passcode',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                        ] else ...[
                          // Info about provider activation for other reasons
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              border: Border.all(color: Colors.blue.shade200),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.verified_user,
                                  color: Colors.blue.shade600,
                                  size: 32,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Provider Activation Required',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.blue.shade800,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Your account must be manually activated by a provider. Please contact your provider for activation.',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.blue.shade700,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Sign out button
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              _activationCheckTimer?.cancel();
                              await FirebaseAuth.instance.signOut();
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.grey.shade700,
                              side: BorderSide(color: Colors.grey.shade400),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.logout),
                            label: const Text(
                              'Sign Out',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoginForm extends StatefulWidget {
  const _LoginForm();

  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } on FirebaseAuthException catch (e) {
      String message = 'An error occurred. Please try again.';

      switch (e.code) {
        case 'user-not-found':
          message = 'No user found with this email address.';
          break;
        case 'wrong-password':
          message = 'Incorrect password. Please try again.';
          break;
        case 'invalid-email':
          message = 'Please enter a valid email address.';
          break;
        case 'user-disabled':
          message = 'This account has been disabled.';
          break;
        case 'too-many-requests':
          message = 'Too many failed attempts. Please try again later.';
          break;
        case 'invalid-credential':
          message = 'Invalid email or password. Please check your credentials.';
          break;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('An unexpected error occurred. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Email field
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Email',
              hintText: 'Enter your email',
              prefixIcon: const Icon(Icons.email_outlined),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.deepPurple),
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter your email';
              }
              if (!RegExp(
                r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
              ).hasMatch(value)) {
                return 'Please enter a valid email';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // Password field
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _signIn(),
            decoration: InputDecoration(
              labelText: 'Password',
              hintText: 'Enter your password',
              prefixIcon: const Icon(Icons.lock_outlined),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () {
                  setState(() {
                    _obscurePassword = !_obscurePassword;
                  });
                },
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.deepPurple),
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter your password';
              }
              if (value.length < 6) {
                return 'Password must be at least 6 characters';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),

          // Sign in button
          SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _signIn,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              child:
                  _isLoading
                      ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                      : const Text(
                        'Sign In',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
            ),
          ),
        ],
      ),
    );
  }
}

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Create Firebase Auth user first
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );

      // Update display name if provided
      if (_nameController.text.trim().isNotEmpty) {
        await credential.user?.updateDisplayName(_nameController.text.trim());
      }

      // Create user document in Firestore (starts inactive, no provider link)
      await FirebaseFirestore.instance
          .collection('users')
          .doc(credential.user!.uid)
          .set({
            'email': _emailController.text.trim(),
            'name':
                _nameController.text.trim().isNotEmpty
                    ? _nameController.text.trim()
                    : null,
            'active':
                false, // Users start inactive until provider manually activates them
            'createdAt': FieldValue.serverTimestamp(),
            'lastUpdated': FieldValue.serverTimestamp(),
          });

      // Ensure document is created before proceeding
      // Wait a moment and verify the document exists
      await Future.delayed(Duration(milliseconds: 500));
      final verifyDoc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(credential.user!.uid)
              .get();

      if (!verifyDoc.exists) {
        print('Warning: User document not found after creation, retrying...');
        // Retry document creation
        await FirebaseFirestore.instance
            .collection('users')
            .doc(credential.user!.uid)
            .set({
              'email': _emailController.text.trim(),
              'name':
                  _nameController.text.trim().isNotEmpty
                      ? _nameController.text.trim()
                      : null,
              'active': false,
              'createdAt': FieldValue.serverTimestamp(),
              'lastUpdated': FieldValue.serverTimestamp(),
            });
      }

      if (mounted) {
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Registration successful! Your account is pending activation by a provider.',
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
          ),
        );

        // Navigate back to login
        Navigator.of(context).pop();
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String errorMessage = 'Registration failed. Please try again.';

        switch (e.code) {
          case 'weak-password':
            errorMessage =
                'Password is too weak. Please choose a stronger password.';
            break;
          case 'email-already-in-use':
            errorMessage = 'An account with this email already exists.';
            break;
          case 'invalid-email':
            errorMessage = 'Please enter a valid email address.';
            break;
          default:
            errorMessage =
                e.message ?? 'Registration failed. Please try again.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('An unexpected error occurred. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.deepPurple),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Create Account',
          style: TextStyle(
            color: Colors.deepPurple,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Logo
                      Center(
                        child: Image.asset(
                          'assets/images/TRUEBALANCE-PAINRELIEF_LOGO_DARK_2256x504.png',
                          height: 60,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            return const Text(
                              'TrueBalance Client',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.deepPurple,
                              ),
                              textAlign: TextAlign.center,
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Title
                      const Text(
                        'Create Your Account',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: Colors.deepPurple,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Please fill in your details to register',
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),

                      // Name field (first)
                      TextFormField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Name (Optional)',
                          hintText: 'Enter your name',
                          prefixIcon: const Icon(Icons.person_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Colors.deepPurple,
                            ),
                          ),
                        ),
                        validator: (value) {
                          // Only validate if something is entered
                          if (value != null &&
                              value.trim().isNotEmpty &&
                              value.trim().length < 2) {
                            return 'Name must be at least 2 characters';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Email field
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Email',
                          hintText: 'Enter your email address',
                          prefixIcon: const Icon(Icons.email_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Colors.deepPurple,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter your email';
                          }
                          if (!RegExp(
                            r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
                          ).hasMatch(value.trim())) {
                            return 'Please enter a valid email address';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Password field
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          hintText: 'Create a strong password',
                          prefixIcon: const Icon(Icons.lock_outlined),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Colors.deepPurple,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter a password';
                          }
                          if (value.length < 6) {
                            return 'Password must be at least 6 characters';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Confirm Password field
                      TextFormField(
                        controller: _confirmPasswordController,
                        obscureText: _obscureConfirmPassword,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _register(),
                        decoration: InputDecoration(
                          labelText: 'Confirm Password',
                          hintText: 'Re-enter your password',
                          prefixIcon: const Icon(Icons.lock_outlined),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureConfirmPassword
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscureConfirmPassword =
                                    !_obscureConfirmPassword;
                              });
                            },
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Colors.deepPurple,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please confirm your password';
                          }
                          if (value != _passwordController.text) {
                            return 'Passwords do not match';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),

                      // Register button
                      SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _register,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurple,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 2,
                          ),
                          child:
                              _isLoading
                                  ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                  : const Text(
                                    'Create Account',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Info text
                      Text(
                        'After registration, your account will be inactive until manually activated by a provider.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum TimeRange { week, month, year, allTime }

class PainHistoryView extends StatefulWidget {
  final String userId;

  const PainHistoryView({super.key, required this.userId});

  @override
  State<PainHistoryView> createState() => _PainHistoryViewState();
}

class _PainHistoryViewState extends State<PainHistoryView> {
  TimeRange selectedTimeRange = TimeRange.week;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          'Pain History',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),

        // Time range selector
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children:
                  TimeRange.values.map((range) {
                    final isSelected = selectedTimeRange == range;
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          selectedTimeRange = range;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color:
                              isSelected
                                  ? Colors.deepPurple
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _getTimeRangeLabel(range),
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.black87,
                            fontWeight:
                                isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
            ),
          ),
        ),
        const SizedBox(height: 20),

        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream:
                FirebaseFirestore.instance
                    .collection('painLevels')
                    .where('userId', isEqualTo: widget.userId)
                    .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                print('Firestore query error: ${snapshot.error}');
                if (snapshot.error.toString().contains('index')) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.warning_amber,
                          size: 48,
                          color: Colors.orange,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Setting up pain tracking...',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Firestore index is being created.\nThis may take a few minutes.',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () {
                            final errorString = snapshot.error.toString();
                            final urlMatch = RegExp(
                              r'https://console\.firebase\.google\.com[^\s,}]+',
                            ).firstMatch(errorString);
                            if (urlMatch != null) {
                              launchUrl(Uri.parse(urlMatch.group(0)!));
                            }
                          },
                          child: const Text('Create Index in Firebase Console'),
                        ),
                      ],
                    ),
                  );
                }
                return Center(
                  child: Text(
                    'Error loading pain history:\n${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: Colors.red),
                  ),
                );
              }

              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return const Center(
                  child: Text(
                    'No pain history recorded yet.\nStart tracking your pain levels!',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                );
              }

              // Filter and sort data based on selected time range
              final filteredData = _filterDataByTimeRange(snapshot.data!.docs);

              if (filteredData.isEmpty) {
                return Center(
                  child: Text(
                    'No pain data for selected ${_getTimeRangeLabel(selectedTimeRange).toLowerCase()} period.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                );
              }

              return Column(
                children: [
                  // Summary stats
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildStatItem(
                          'Entries',
                          filteredData.length.toString(),
                        ),
                        _buildStatItem(
                          'Avg Pain',
                          _calculateAverage(filteredData),
                        ),
                        _buildStatItem(
                          'Latest',
                          filteredData.isNotEmpty
                              ? (filteredData.last.data()
                                          as Map<String, dynamic>)['painLevel']
                                      ?.toString() ??
                                  'N/A'
                              : 'N/A',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Line chart
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // Ensure minimum height for the chart
                        final chartHeight = constraints.maxHeight.clamp(
                          200.0,
                          double.infinity,
                        );
                        return Container(
                          height: chartHeight,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[300]!),
                          ),
                          child: PainLineChart(
                            data: filteredData,
                            timeRange: selectedTimeRange,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          child: const Text('Close'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  String _getTimeRangeLabel(TimeRange range) {
    switch (range) {
      case TimeRange.week:
        return '1 Week';
      case TimeRange.month:
        return '1 Month';
      case TimeRange.year:
        return '1 Year';
      case TimeRange.allTime:
        return 'All Time';
    }
  }

  List<QueryDocumentSnapshot> _filterDataByTimeRange(
    List<QueryDocumentSnapshot> docs,
  ) {
    final now = DateTime.now();
    DateTime cutoffDate;

    switch (selectedTimeRange) {
      case TimeRange.week:
        cutoffDate = now.subtract(const Duration(days: 7));
        break;
      case TimeRange.month:
        cutoffDate = now.subtract(const Duration(days: 30));
        break;
      case TimeRange.year:
        cutoffDate = now.subtract(const Duration(days: 365));
        break;
      case TimeRange.allTime:
        return docs..sort((a, b) {
          final aData = a.data() as Map<String, dynamic>;
          final bData = b.data() as Map<String, dynamic>;
          final aTimestamp = aData['timestamp'] as Timestamp?;
          final bTimestamp = bData['timestamp'] as Timestamp?;

          if (aTimestamp == null && bTimestamp == null) return 0;
          if (aTimestamp == null) return 1;
          if (bTimestamp == null) return -1;

          return aTimestamp.compareTo(
            bTimestamp,
          ); // Ascending order (oldest first)
        });
    }

    final filtered =
        docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final timestamp = data['timestamp'] as Timestamp?;
          if (timestamp == null) return false;
          return timestamp.toDate().isAfter(cutoffDate);
        }).toList();

    // Sort by timestamp ascending (oldest first for charting)
    filtered.sort((a, b) {
      final aData = a.data() as Map<String, dynamic>;
      final bData = b.data() as Map<String, dynamic>;
      final aTimestamp = aData['timestamp'] as Timestamp?;
      final bTimestamp = bData['timestamp'] as Timestamp?;

      if (aTimestamp == null && bTimestamp == null) return 0;
      if (aTimestamp == null) return 1;
      if (bTimestamp == null) return -1;

      return aTimestamp.compareTo(bTimestamp);
    });

    return filtered;
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.deepPurple,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  String _calculateAverage(List<QueryDocumentSnapshot> entries) {
    if (entries.isEmpty) return '0.0';

    double sum = 0;
    int count = 0;

    for (var entry in entries) {
      final data = entry.data() as Map<String, dynamic>;
      final painLevel = data['painLevel'];
      if (painLevel != null && painLevel is num) {
        sum += painLevel.toDouble();
        count++;
      }
    }

    if (count == 0) return '0.0';
    return (sum / count).toStringAsFixed(1);
  }
}

class PainLineChart extends StatefulWidget {
  final List<QueryDocumentSnapshot> data;
  final TimeRange timeRange;

  const PainLineChart({super.key, required this.data, required this.timeRange});

  @override
  State<PainLineChart> createState() => _PainLineChartState();
}

class _PainLineChartState extends State<PainLineChart> {
  int? hoveredPointIndex;
  Offset? tapPosition;
  Timer? _hoverDebounceTimer;

  @override
  void dispose() {
    _hoverDebounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty) {
      return const Center(
        child: Text('No data to display', style: TextStyle(color: Colors.grey)),
      );
    }

    return Stack(
      children: [
        GestureDetector(
          onTapDown: (TapDownDetails details) {
            _handleTap(details.localPosition);
          },
          child: MouseRegion(
            onHover: (event) {
              _handleHover(event.localPosition);
            },
            onExit: (event) {
              _hoverDebounceTimer?.cancel();
              _hoverDebounceTimer = Timer(
                const Duration(milliseconds: 100),
                () {
                  if (mounted) {
                    setState(() {
                      hoveredPointIndex = null;
                    });
                  }
                },
              );
            },
            child: CustomPaint(
              size: Size.infinite,
              painter: LineChartPainter(
                data: widget.data,
                timeRange: widget.timeRange,
                hoveredPointIndex: hoveredPointIndex,
              ),
            ),
          ),
        ),
        if (hoveredPointIndex != null && tapPosition != null) _buildTooltip(),
      ],
    );
  }

  void _handleTap(Offset position) {
    final pointIndex = _getPointIndexAtPosition(position);
    if (pointIndex != null) {
      setState(() {
        hoveredPointIndex = pointIndex;
        tapPosition = position;
      });
    } else {
      setState(() {
        hoveredPointIndex = null;
        tapPosition = null;
      });
    }
  }

  void _handleHover(Offset position) {
    // Cancel any existing timer
    _hoverDebounceTimer?.cancel();

    final pointIndex = _getPointIndexAtPosition(position);

    // Only update state if the hovered point actually changed
    if (pointIndex != hoveredPointIndex) {
      // Add a small delay to prevent rapid flickering
      _hoverDebounceTimer = Timer(const Duration(milliseconds: 50), () {
        if (mounted) {
          setState(() {
            hoveredPointIndex = pointIndex;
            if (pointIndex != null) {
              tapPosition = position;
            }
          });
        }
      });
    } else if (pointIndex != null) {
      // If same point but position changed, update position immediately
      setState(() {
        tapPosition = position;
      });
    }
  }

  int? _getPointIndexAtPosition(Offset position) {
    const double leftMargin = 80;
    const double rightMargin = 20;
    const double topMargin = 20;
    const double bottomMargin = 50;

    // Get render box to calculate actual size
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;

    final size = renderBox.size;
    final chartWidth = size.width - leftMargin - rightMargin;
    final chartHeight = size.height - topMargin - bottomMargin;

    // Extract timestamps for time-based positioning
    final timestamps = <DateTime>[];
    for (int i = 0; i < widget.data.length; i++) {
      final docData = widget.data[i].data() as Map<String, dynamic>;
      final timestamp = docData['timestamp'] as Timestamp?;
      if (timestamp != null) {
        timestamps.add(timestamp.toDate());
      }
    }

    if (timestamps.isEmpty) return null;

    // Calculate time-based positions using full selected time window
    DateTime earliestTime;
    DateTime latestTime = DateTime.now();

    switch (widget.timeRange) {
      case TimeRange.week:
        earliestTime = latestTime.subtract(const Duration(days: 7));
        break;
      case TimeRange.month:
        earliestTime = latestTime.subtract(const Duration(days: 30));
        break;
      case TimeRange.year:
        earliestTime = latestTime.subtract(const Duration(days: 365));
        break;
      case TimeRange.allTime:
        // For "All Time", use actual data range
        earliestTime = timestamps.reduce((a, b) => a.isBefore(b) ? a : b);
        latestTime = timestamps.reduce((a, b) => a.isAfter(b) ? a : b);
        break;
    }

    final totalTimeSpan =
        latestTime.millisecondsSinceEpoch - earliestTime.millisecondsSinceEpoch;

    for (int i = 0; i < timestamps.length; i++) {
      final timestamp = timestamps[i];
      final docData = widget.data[i].data() as Map<String, dynamic>;
      final painLevel = (docData['painLevel'] ?? 0).toDouble();

      // Calculate point position based on timestamp
      final timeProgress =
          totalTimeSpan > 0
              ? (timestamp.millisecondsSinceEpoch -
                      earliestTime.millisecondsSinceEpoch) /
                  totalTimeSpan
              : (i / (timestamps.length - 1).clamp(1, double.infinity));

      final pointX = leftMargin + timeProgress * chartWidth;
      final pointY = topMargin + chartHeight - (painLevel / 10) * chartHeight;

      // Check if tap/hover position is near this point (within 15 pixels)
      final distance = (Offset(pointX, pointY) - position).distance;
      if (distance <= 15) {
        return i;
      }
    }

    return null;
  }

  Widget _buildTooltip() {
    if (hoveredPointIndex == null || tapPosition == null) {
      return const SizedBox.shrink();
    }

    final docData =
        widget.data[hoveredPointIndex!].data() as Map<String, dynamic>;
    final painLevel = docData['painLevel'] ?? 0;
    final notes = docData['notes'] as String?;
    final timestamp = docData['timestamp'] as Timestamp?;

    final tooltipContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pain Level: $painLevel',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: Colors.white,
          ),
        ),
        if (timestamp != null) ...[
          const SizedBox(height: 4),
          Text(
            _formatDateTime(timestamp.toDate()),
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
        if (notes != null && notes.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            'Notes:',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Container(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              notes.trim(),
              style: const TextStyle(fontSize: 12, color: Colors.white),
              softWrap: true,
            ),
          ),
        ],
      ],
    );

    // Calculate tooltip position with better boundary handling
    const double tooltipWidth = 220;
    const double tooltipPadding = 20;

    double tooltipX = tapPosition!.dx;
    double tooltipY = tapPosition!.dy - 10;

    // Get render box to check boundaries
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final size = renderBox.size;

      // Handle horizontal positioning with better logic
      if (tooltipX + tooltipWidth > size.width - tooltipPadding) {
        // Position tooltip to the left of the point
        tooltipX = tapPosition!.dx - tooltipWidth - 15;
      }

      // Ensure tooltip doesn't go off the left edge
      if (tooltipX < tooltipPadding) {
        tooltipX = tooltipPadding;
      }

      // Handle vertical positioning
      if (tooltipY < tooltipPadding) {
        tooltipY = tapPosition!.dy + 30; // Position below the point
      }

      // Ensure tooltip doesn't go off the bottom
      if (tooltipY > size.height - 120) {
        // Estimate tooltip height
        tooltipY = tapPosition!.dy - 80;
      }
    }

    return Positioned(
      left: tooltipX,
      top: tooltipY,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: tooltipContent,
          ),
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.month}/${dateTime.day}/${dateTime.year} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}

class LineChartPainter extends CustomPainter {
  final List<QueryDocumentSnapshot> data;
  final TimeRange timeRange;
  final int? hoveredPointIndex;

  LineChartPainter({
    required this.data,
    required this.timeRange,
    this.hoveredPointIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = Colors.deepPurple
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;

    final gridPaint =
        Paint()
          ..color = Colors.grey[300]!
          ..strokeWidth = 1;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // Chart margins
    const double leftMargin = 80; // Increased even more for Y-axis label
    const double rightMargin = 20;
    const double topMargin = 20;
    const double bottomMargin = 50; // Increased for X-axis labels

    final chartWidth = size.width - leftMargin - rightMargin;
    final chartHeight = size.height - topMargin - bottomMargin;

    // Draw grid lines and Y-axis labels (pain levels 0-10)
    for (int i = 0; i <= 10; i++) {
      final y = topMargin + chartHeight - (i / 10) * chartHeight;

      // Grid line
      canvas.drawLine(
        Offset(leftMargin, y),
        Offset(leftMargin + chartWidth, y),
        gridPaint,
      );

      // Y-axis label
      textPainter.text = TextSpan(
        text: i.toString(),
        style: const TextStyle(color: Colors.black87, fontSize: 12),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(leftMargin - 50, y - 6));
    }

    // Draw Y-axis title
    canvas.save();
    canvas.translate(
      12,
      topMargin + chartHeight / 2,
    ); // Moved even further left
    canvas.rotate(-3.14159 / 2);
    textPainter.text = const TextSpan(
      text: 'Pain Level',
      style: TextStyle(
        color: Colors.black87,
        fontSize: 11,
        fontWeight: FontWeight.bold,
      ),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(-textPainter.width / 2, 0));
    canvas.restore();

    if (data.isEmpty) return;

    // Extract data points and timestamps first
    final timestamps = <DateTime>[];
    final painLevels = <double>[];

    for (int i = 0; i < data.length; i++) {
      final docData = data[i].data() as Map<String, dynamic>;
      final painLevel = (docData['painLevel'] ?? 0).toDouble();
      final timestamp = docData['timestamp'] as Timestamp?;

      if (timestamp != null) {
        timestamps.add(timestamp.toDate());
        painLevels.add(painLevel);
      }
    }

    if (timestamps.isEmpty) return;

    // Calculate time-based X positions using full selected time window
    final points = <Offset>[];
    DateTime earliestTime;
    DateTime latestTime = DateTime.now();

    switch (timeRange) {
      case TimeRange.week:
        earliestTime = latestTime.subtract(const Duration(days: 7));
        break;
      case TimeRange.month:
        earliestTime = latestTime.subtract(const Duration(days: 30));
        break;
      case TimeRange.year:
        earliestTime = latestTime.subtract(const Duration(days: 365));
        break;
      case TimeRange.allTime:
        // For "All Time", use actual data range
        earliestTime = timestamps.reduce((a, b) => a.isBefore(b) ? a : b);
        latestTime = timestamps.reduce((a, b) => a.isAfter(b) ? a : b);
        break;
    }

    final totalTimeSpan =
        latestTime.millisecondsSinceEpoch - earliestTime.millisecondsSinceEpoch;

    for (int i = 0; i < timestamps.length; i++) {
      final timestamp = timestamps[i];
      final painLevel = painLevels[i];

      // Calculate X position based on exact timestamp (including time of day)
      final timeProgress =
          totalTimeSpan > 0
              ? (timestamp.millisecondsSinceEpoch -
                      earliestTime.millisecondsSinceEpoch) /
                  totalTimeSpan
              : (i / (timestamps.length - 1).clamp(1, double.infinity));

      final x = leftMargin + timeProgress * chartWidth;
      final y = topMargin + chartHeight - (painLevel / 10) * chartHeight;

      points.add(Offset(x, y));
    }

    // Draw the line chart
    if (points.length > 1) {
      final path = Path();
      path.moveTo(points.first.dx, points.first.dy);

      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }

      canvas.drawPath(path, paint);
    }

    // Draw data points and collect labels to show (with overlap prevention)
    List<Map<String, dynamic>> labelsToShow = [];

    for (int i = 0; i < points.length; i++) {
      final point = points[i];
      final isHovered = hoveredPointIndex == i;

      // Use different paint for hovered point
      final currentPointPaint =
          Paint()
            ..color = isHovered ? Colors.deepPurple.shade700 : Colors.deepPurple
            ..style = PaintingStyle.fill;

      // Draw larger circle if hovered
      final radius = isHovered ? 6.0 : 4.0;
      canvas.drawCircle(point, radius, currentPointPaint);

      // Draw white border for hovered point
      if (isHovered) {
        final borderPaint =
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2;
        canvas.drawCircle(point, radius, borderPaint);
      }

      // Collect pain level labels - show all for week/month, smart selection for year/allTime
      final painLevel = painLevels[i].toInt();

      // Determine point characteristics
      bool isPeak = false;
      bool isLow = false;
      bool isSignificant = false;

      if (painLevels.length >= 3) {
        if (i == 0) {
          // First point: compare with next point
          isPeak = painLevels[i] > painLevels[i + 1];
          isLow = painLevels[i] < painLevels[i + 1];
        } else if (i == painLevels.length - 1) {
          // Last point: compare with previous point
          isPeak = painLevels[i] > painLevels[i - 1];
          isLow = painLevels[i] < painLevels[i - 1];
        } else {
          // Middle point: compare with both neighbors
          isPeak =
              painLevels[i] > painLevels[i - 1] &&
              painLevels[i] > painLevels[i + 1];
          isLow =
              painLevels[i] < painLevels[i - 1] &&
              painLevels[i] < painLevels[i + 1];
        }
      }

      // Check if point represents a significant change (useful for longer time periods)
      if (painLevels.length >= 2) {
        double changeThreshold =
            1.0; // At least 1 point difference is significant
        if (i > 0) {
          isSignificant =
              (painLevels[i] - painLevels[i - 1]).abs() >= changeThreshold;
        }
        if (i < painLevels.length - 1) {
          isSignificant =
              isSignificant ||
              (painLevels[i + 1] - painLevels[i]).abs() >= changeThreshold;
        }
      }

      bool shouldShowLabel = false;
      bool isLowPoint = false; // For positioning label below the line
      int priority = 0; // Higher priority labels are more likely to be shown

      if (timeRange == TimeRange.week || timeRange == TimeRange.month) {
        // Show all labels for week and month views
        shouldShowLabel = true;
        priority = 1;
      } else if (timeRange == TimeRange.year ||
          timeRange == TimeRange.allTime) {
        // For year/allTime, collect all potential labels with priorities
        shouldShowLabel = true; // We'll filter later based on spacing

        // Assign priorities (higher = more important)
        if (isHovered) {
          priority = 100; // Highest priority
        } else if (isPeak || isLow) {
          priority = 10; // High priority for peaks and lows
        } else if (isSignificant) {
          priority = 5; // Medium priority for significant changes
        } else {
          priority = 1; // Low priority for regular points
        }

        isLowPoint = isLow;
      }

      // Always show label if hovered (override positioning)
      if (isHovered) {
        shouldShowLabel = true;
        isLowPoint = false; // Hovered labels always go above
        priority = 100;
      }

      if (shouldShowLabel) {
        // Calculate label position
        double labelY;
        if (isLowPoint && !isHovered) {
          labelY = point.dy + 15; // Below the point for lows
        } else {
          labelY =
              point.dy -
              (isHovered ? 25 : 20); // Above the point for peaks/hovered
        }

        labelsToShow.add({
          'text': painLevel.toString(),
          'pointX': point.dx,
          'labelY': labelY,
          'isHovered': isHovered,
          'isLowPoint': isLowPoint,
          'priority': priority,
          'isPeak': isPeak,
          'isLow': isLow,
          'isSignificant': isSignificant,
        });
      }
    }

    // Smart label filtering for year/allTime views
    if (timeRange == TimeRange.year || timeRange == TimeRange.allTime) {
      const double minHorizontalDistance =
          32; // Minimum pixels between label centers

      // Sort by priority (highest first), then by x position for equal priorities
      labelsToShow.sort((a, b) {
        int priorityComparison = b['priority'].compareTo(a['priority']);
        if (priorityComparison != 0) return priorityComparison;
        return a['pointX'].compareTo(b['pointX']);
      });

      List<Map<String, dynamic>> filteredLabels = [];

      for (var label in labelsToShow) {
        bool canPlace = true;

        // Check if this label would overlap with any already accepted label
        for (var existing in filteredLabels) {
          double horizontalDistance =
              (label['pointX'] - existing['pointX']).abs();

          // Different rules for different positioning:
          // - Same positioning (both above or both below): need full horizontal distance
          // - Different positioning (one above, one below): can be closer together
          double requiredDistance;
          if (label['isLowPoint'] == existing['isLowPoint']) {
            // Same positioning - need full distance
            requiredDistance = minHorizontalDistance;
          } else {
            // Different positioning - can be closer
            requiredDistance = minHorizontalDistance * 0.6; // About 20 pixels
          }

          if (horizontalDistance < requiredDistance) {
            // Check priorities - keep the higher priority label
            if (label['priority'] > existing['priority']) {
              // Remove the lower priority existing label
              filteredLabels.removeWhere((item) => item == existing);
            } else {
              // Skip this lower priority label
              canPlace = false;
              break;
            }
          }
        }

        if (canPlace) {
          filteredLabels.add(label);
        }
      }

      // Sort final labels by x position for consistent drawing order
      filteredLabels.sort((a, b) => a['pointX'].compareTo(b['pointX']));
      labelsToShow = filteredLabels;
    }

    // Draw the filtered labels
    for (var label in labelsToShow) {
      textPainter.text = TextSpan(
        text: label['text'],
        style: TextStyle(
          color:
              label['isHovered'] ? Colors.deepPurple.shade700 : Colors.black87,
          fontSize: label['isHovered'] ? 11 : 10,
          fontWeight: FontWeight.bold,
        ),
      );
      textPainter.layout();

      textPainter.paint(
        canvas,
        Offset(label['pointX'] - textPainter.width / 2, label['labelY']),
      );
    }

    // Draw X-axis labels across the full time window
    if (timeRange != TimeRange.allTime) {
      // For fixed time windows (week/month/year), generate evenly spaced labels
      int labelCount;
      switch (timeRange) {
        case TimeRange.week:
          labelCount = 7; // One label per day
          break;
        case TimeRange.month:
          labelCount = 6; // About 5-day intervals
          break;
        case TimeRange.year:
          labelCount = 12; // About monthly intervals
          break;
        case TimeRange.allTime:
          labelCount = 5; // Fallback (won't be used)
          break;
      }

      for (int i = 0; i <= labelCount; i++) {
        final timeProgress = i / labelCount;
        final labelTime = DateTime.fromMillisecondsSinceEpoch(
          earliestTime.millisecondsSinceEpoch +
              (totalTimeSpan * timeProgress).round(),
        );
        final labelX = leftMargin + timeProgress * chartWidth;

        textPainter.text = TextSpan(
          text: _formatTimestamp(labelTime),
          style: const TextStyle(color: Colors.black87, fontSize: 10),
        );
        textPainter.layout();

        canvas.save();
        canvas.translate(labelX, size.height - bottomMargin + 15);

        // Use different rotation angles based on time range to prevent overlap
        double rotationAngle;
        switch (timeRange) {
          case TimeRange.week:
          case TimeRange.month:
            rotationAngle = -0.8; // Steeper angle for short ranges
            break;
          case TimeRange.year:
          case TimeRange.allTime:
            rotationAngle =
                -1.57; // Completely vertical (90 degrees) for long ranges
            break;
        }

        canvas.rotate(rotationAngle);
        textPainter.paint(canvas, Offset(-textPainter.width / 2, 0));
        canvas.restore();
      }
    } else {
      // For "All Time", use data point-based labels as before
      if (timestamps.isNotEmpty) {
        final labelCount = (timestamps.length / 7).ceil().clamp(
          2,
          10,
        ); // Show max 10 labels
        final labelInterval = (timestamps.length / labelCount).floor().clamp(
          1,
          timestamps.length,
        );

        for (int i = 0; i < timestamps.length; i += labelInterval) {
          if (i < points.length) {
            final point = points[i];
            final timestamp = timestamps[i];

            textPainter.text = TextSpan(
              text: _formatTimestamp(timestamp),
              style: const TextStyle(color: Colors.black87, fontSize: 10),
            );
            textPainter.layout();

            canvas.save();
            canvas.translate(point.dx, size.height - bottomMargin + 15);
            canvas.rotate(-1.57); // Vertical for all time
            textPainter.paint(canvas, Offset(-textPainter.width / 2, 0));
            canvas.restore();
          }
        }
      }
    }
  }

  String _formatTimestamp(DateTime timestamp) {
    switch (timeRange) {
      case TimeRange.week:
        return '${timestamp.month}/${timestamp.day}';
      case TimeRange.month:
        return '${timestamp.month}/${timestamp.day}';
      case TimeRange.year:
        return '${timestamp.month}/${timestamp.year}';
      case TimeRange.allTime:
        return '${timestamp.month}/${timestamp.year}';
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Track which exercise is currently showing congratulatory text
  static String? _currentCongratulatoryExercise;

  @override
  void initState() {
    super.initState();
    // Clear any congratulatory text when the screen initializes/refreshes
    _currentCongratulatoryExercise = null;
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
    int selectedPainLevel = 5;
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
                      'Rate your current pain level (1 = minimal, 10 = severe):',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(10, (index) {
                        final level = index + 1;
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              selectedPainLevel = level;
                            });
                          },
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color:
                                  selectedPainLevel == level
                                      ? _getPainLevelColor(level)
                                      : Colors.grey[300],
                              border: Border.all(
                                color:
                                    selectedPainLevel == level
                                        ? Colors.black
                                        : Colors.grey,
                                width: selectedPainLevel == level ? 2 : 1,
                              ),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Center(
                              child: Text(
                                level.toString(),
                                style: TextStyle(
                                  color:
                                      selectedPainLevel == level
                                          ? Colors.white
                                          : Colors.black,
                                  fontWeight: FontWeight.bold,
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
                    await _savePainLevel(
                      userId,
                      selectedPainLevel,
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
    if (level <= 2) return Colors.green;
    if (level <= 4) return Colors.lightGreen;
    if (level <= 6) return Colors.yellow;
    if (level <= 8) return Colors.orange;
    return Colors.red;
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

  // Notification settings dialog
  void _showNotificationSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Exercise Reminder Settings'),
              content: FutureBuilder<Map<String, dynamic>>(
                future: () async {
                  final isEnabled =
                      await ExerciseReminderManager.areRemindersEnabled();
                  final intervalHours =
                      await ExerciseReminderManager.getNotificationIntervalHours();
                  return {
                    'isEnabled': isEnabled,
                    'intervalHours': intervalHours,
                  };
                }(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const CircularProgressIndicator();
                  }

                  final data = snapshot.data!;
                  final isEnabled = data['isEnabled'] as bool;
                  final intervalHours = data['intervalHours'] as int;

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Get reminders to complete your exercises if you haven\'t done them in the configured time period.',
                        style: TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        title: const Text('Enable Exercise Reminders'),
                        subtitle: Text(
                          isEnabled
                              ? 'You will receive notifications'
                              : 'No notifications will be sent',
                        ),
                        value: isEnabled,
                        onChanged: (bool value) async {
                          await ExerciseReminderManager.setRemindersEnabled(
                            value,
                          );
                          setState(() {}); // Refresh the dialog
                        },
                      ),
                      if (isEnabled) ...[
                        const SizedBox(height: 16),
                        const Text(
                          'Remind me every:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: intervalHours.clamp(1, 48),
                              isExpanded: true,
                              items: List.generate(48, (index) {
                                final hours = index + 1;
                                return DropdownMenuItem<int>(
                                  value: hours,
                                  child: Text(
                                    hours == 1 ? '$hours hour' : '$hours hours',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                );
                              }),
                              onChanged: (int? newHours) async {
                                if (newHours != null) {
                                  await ExerciseReminderManager.setNotificationIntervalHours(
                                    newHours,
                                  );
                                  setState(() {}); // Refresh the dialog
                                }
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'You will receive reminders every $intervalHours hour${intervalHours == 1 ? '' : 's'} after your most recent exercise.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'ℹ️ Notifications will only be sent once per day and only if you have exercises assigned but haven\'t completed any in the last $intervalHours hours.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.notifications_active),
                          label: const Text('Test Notification'),
                          onPressed: () async {
                            await ExerciseReminderManager.triggerTestNotification();
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Test notification sent!'),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  );
                },
              ),
              actions: [
                TextButton(
                  child: const Text('Close'),
                  onPressed: () {
                    Navigator.of(context).pop();
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
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
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
                  ),
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

  // Static method to clear congratulatory text
  static void clearCongratulatoryText() {
    _HomeScreenState._currentCongratulatoryExercise = null;
  }

  // Static method to set congratulatory text for a specific exercise
  static void setCongratulatoryExercise(String exerciseId) {
    _HomeScreenState._currentCongratulatoryExercise = exerciseId;
  }

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
        final documents = exercise['documents'];
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
          tilePadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ), // Reduced vertical padding to minimize gaps
          trailing: SizedBox(
            width: 120, // Fixed width to contain our vertical layout
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Last check-in display and Did it button in vertical layout
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
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
                        final latestData =
                            latestDoc.data() as Map<String, dynamic>;
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

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // Did it button at the top
                          ElevatedButton(
                            onPressed: () async {
                              final user = FirebaseAuth.instance.currentUser;
                              if (user != null) {
                                // Clear any existing congratulatory text
                                ExerciseTile.clearCongratulatoryText();

                                await FirebaseFirestore.instance
                                    .collection('exercise_check_ins')
                                    .add({
                                      'userId': user.uid,
                                      'exerciseId': exerciseId,
                                      'timestamp': FieldValue.serverTimestamp(),
                                    });

                                // Set congratulatory text for this exercise
                                ExerciseTile.setCongratulatoryExercise(
                                  exerciseId,
                                );

                                // Notify the reminder system that an exercise was completed
                                await ExerciseReminderManager.onExerciseCompleted();
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  doneToday ? Colors.grey : Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              minimumSize: const Size(70, 18), // Compact button
                            ),
                            child: Text(
                              doneToday
                                  ? (_HomeScreenState
                                              ._currentCongratulatoryExercise ==
                                          exerciseId
                                      ? () {
                                        final congratsMessages = [
                                          'Good job!',
                                          'Nice!',
                                          'Awesome!',
                                          'Well done!',
                                          'Great work!',
                                          'Excellent!',
                                          'Fantastic!',
                                          'Keep it up!',
                                          'Amazing!',
                                          'Outstanding!',
                                        ];
                                        return congratsMessages[DateTime.now()
                                                .millisecondsSinceEpoch %
                                            congratsMessages.length];
                                      }()
                                      : 'Did it again!')
                                  : 'Did it!',
                              style: const TextStyle(
                                fontSize: 9,
                              ), // Smaller font to fit in compact button
                            ),
                          ),
                          const SizedBox(
                            height: 4,
                          ), // Small spacing between button and text
                          // Last check-in display below button
                          if (lastCheckIn != null)
                            Container(
                              constraints: const BoxConstraints(
                                minHeight: 20,
                              ), // Ensure minimum height for text
                              width: double.infinity,
                              child: Builder(
                                builder: (context) {
                                  final checkIn = lastCheckIn;
                                  if (checkIn == null) return const SizedBox();

                                  if (doneToday) {
                                    final now = DateTime.now();
                                    final diff = now.difference(checkIn);
                                    // Convert to 12-hour format
                                    final hour12 =
                                        checkIn.hour == 0
                                            ? 12
                                            : (checkIn.hour > 12
                                                ? checkIn.hour - 12
                                                : checkIn.hour);
                                    final amPm =
                                        checkIn.hour >= 12 ? 'PM' : 'AM';
                                    final timeStr =
                                        '${hour12}:${checkIn.minute.toString().padLeft(2, '0')} $amPm';

                                    String agoText;
                                    if (diff.inMinutes == 0) {
                                      agoText = 'just now';
                                    } else if (diff.inMinutes < 60) {
                                      agoText = '${diff.inMinutes}m ago';
                                    } else {
                                      final hours = diff.inHours;
                                      final minutes = diff.inMinutes % 60;
                                      if (minutes == 0) {
                                        agoText = '${hours}h ago';
                                      } else {
                                        agoText = '${hours}h ${minutes}m ago';
                                      }
                                    }

                                    return Text(
                                      'Today $timeStr ($agoText)',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      textAlign: TextAlign.right,
                                      maxLines: 2, // Allow 2 lines if needed
                                      overflow: TextOverflow.ellipsis,
                                    );
                                  } else {
                                    return Text(
                                      'Last Done: ${checkIn.month}/${checkIn.day} ${checkIn.hour.toString().padLeft(2, '0')}:${checkIn.minute.toString().padLeft(2, '0')}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.green,
                                      ),
                                      textAlign: TextAlign.right,
                                      maxLines: 2, // Allow 2 lines if needed
                                      overflow: TextOverflow.ellipsis,
                                    );
                                  }
                                },
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.expand_more),
              ],
            ),
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
                    const Text(
                      'Exercise Video:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 200, // Add fixed height constraint
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ExerciseVideoPlayer(
                          videoUrl: videoUrl.toString(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // Documents section
                  if (documents != null &&
                      documents is List &&
                      documents.isNotEmpty) ...[
                    const Text(
                      'Exercise Documents:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...documents.map<Widget>((doc) {
                      if (doc is! Map<String, dynamic>) return const SizedBox();

                      final docTitle = doc['title'] ?? 'Document';
                      final docUrl = doc['url'];
                      final docType = doc['type'] ?? 'unknown';

                      if (docUrl == null || docUrl.toString().isEmpty) {
                        return const SizedBox();
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListTile(
                          leading: Icon(
                            _getDocumentIcon(docType.toString()),
                            color: _getDocumentColor(docType.toString()),
                          ),
                          title: Text(
                            docTitle.toString(),
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            _getDocumentTypeLabel(docType.toString()),
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.open_in_new),
                                tooltip: 'Open',
                                onPressed:
                                    () => _openDocument(docUrl.toString()),
                              ),
                              if (docType.toString().toLowerCase().contains(
                                'pdf',
                              ))
                                IconButton(
                                  icon: const Icon(Icons.download),
                                  tooltip: 'Download',
                                  onPressed:
                                      () => _downloadDocument(
                                        docUrl.toString(),
                                        docTitle.toString(),
                                      ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                    const SizedBox(height: 12),
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

  // Helper methods for document handling
  IconData _getDocumentIcon(String docType) {
    switch (docType.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'google_docs':
      case 'google_doc':
        return Icons.description;
      case 'google_sheets':
      case 'google_sheet':
        return Icons.table_chart;
      case 'google_slides':
      case 'google_slide':
        return Icons.slideshow;
      case 'word':
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'excel':
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'powerpoint':
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getDocumentColor(String docType) {
    switch (docType.toLowerCase()) {
      case 'pdf':
        return Colors.red;
      case 'google_docs':
      case 'google_doc':
      case 'word':
      case 'doc':
      case 'docx':
        return Colors.blue;
      case 'google_sheets':
      case 'google_sheet':
      case 'excel':
      case 'xls':
      case 'xlsx':
        return Colors.green;
      case 'google_slides':
      case 'google_slide':
      case 'powerpoint':
      case 'ppt':
      case 'pptx':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  String _getDocumentTypeLabel(String docType) {
    switch (docType.toLowerCase()) {
      case 'pdf':
        return 'PDF Document';
      case 'google_docs':
      case 'google_doc':
        return 'Google Docs';
      case 'google_sheets':
      case 'google_sheet':
        return 'Google Sheets';
      case 'google_slides':
      case 'google_slide':
        return 'Google Slides';
      case 'word':
      case 'doc':
      case 'docx':
        return 'Word Document';
      case 'excel':
      case 'xls':
      case 'xlsx':
        return 'Excel Spreadsheet';
      case 'powerpoint':
      case 'ppt':
      case 'pptx':
        return 'PowerPoint Presentation';
      default:
        return 'Document';
    }
  }

  Future<void> _openDocument(String url) async {
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw Exception('Could not launch $url');
      }
    } catch (e) {
      // Handle error - could show a snackbar or dialog here
      print('Error opening document: $e');
    }
  }

  Future<void> _downloadDocument(String url, String filename) async {
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw Exception('Could not download $url');
      }
    } catch (e) {
      // Handle error - could show a snackbar or dialog here
      print('Error downloading document: $e');
    }
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

// MessageButtonRow manages the button layout and message input window independently
class MessageButtonRow extends StatefulWidget {
  final User user;
  final Future<Map<String, dynamic>> Function(String) getUnreadMessageInfo;
  final Future<void> Function(String) markProviderMessagesAsRead;
  final String Function(DateTime) formatMessageTime;

  const MessageButtonRow({
    super.key,
    required this.user,
    required this.getUnreadMessageInfo,
    required this.markProviderMessagesAsRead,
    required this.formatMessageTime,
  });

  @override
  State<MessageButtonRow> createState() => _MessageButtonRowState();
}

class _MessageButtonRowState extends State<MessageButtonRow> {
  bool showMessageInput = false;

  void _toggleMessageInput() {
    setState(() {
      showMessageInput = !showMessageInput;
    });
  }

  void _closeMessageInput() {
    setState(() {
      showMessageInput = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Button Row - always takes constrained width
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.notifications_active),
                label: const Text(
                  'Send Me a Nudge',
                  textAlign: TextAlign.center,
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 8,
                  ),
                ),
                onPressed: () async {
                  final now = DateTime.now();
                  await FirebaseFirestore.instance
                      .collection('users')
                      .doc(widget.user.uid)
                      .set({
                        'nudge': 1,
                        'lastNudge': now.toIso8601String(),
                      }, SetOptions(merge: true));
                  // Format timestamp in a user-friendly way
                  final formattedTime =
                      '${now.month}/${now.day}/${now.year} at ${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}';
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Nudge sent on $formattedTime')),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: MessageButton(
                user: widget.user,
                markProviderMessagesAsRead: widget.markProviderMessagesAsRead,
                formatMessageTime: widget.formatMessageTime,
                onPressed: _toggleMessageInput,
              ),
            ),
          ],
        ),
        // Message Input Window - appears independently with full width when toggled
        if (showMessageInput)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: FullWidthMessageInput(
              user: widget.user,
              formatMessageTime: widget.formatMessageTime,
              onClose: _closeMessageInput,
            ),
          ),
      ],
    );
  }
}

// Separate button component that just handles the message button
class MessageButton extends StatelessWidget {
  final User user;
  final Future<void> Function(String) markProviderMessagesAsRead;
  final String Function(DateTime) formatMessageTime;
  final VoidCallback onPressed;

  const MessageButton({
    super.key,
    required this.user,
    required this.markProviderMessagesAsRead,
    required this.formatMessageTime,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream:
          FirebaseFirestore.instance
              .collection('messages')
              .where('userId', isEqualTo: user.uid)
              .where('fromAdmin', isEqualTo: true)
              .snapshots(),
      builder: (context, snapshot) {
        int unreadCount = 0;
        DateTime? latestTimestamp;

        if (snapshot.hasData) {
          final unreadMessages =
              snapshot.data!.docs.where((doc) {
                final data = doc.data() as Map<String, dynamic>;
                return !data.containsKey('read') || data['read'] != true;
              }).toList();

          unreadCount = unreadMessages.length;

          for (var doc in unreadMessages) {
            final data = doc.data() as Map<String, dynamic>;
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
              if (latestTimestamp == null ||
                  messageTime.isAfter(latestTimestamp)) {
                latestTimestamp = messageTime;
              }
            }
          }
        }

        String buttonText;
        if (unreadCount > 0) {
          final timeText =
              latestTimestamp != null
                  ? formatMessageTime(latestTimestamp)
                  : 'recently';

          if (unreadCount == 1) {
            buttonText = '1 New message received ($timeText)';
          } else {
            buttonText = '$unreadCount New messages received ($timeText)';
          }
        } else {
          buttonText = 'Send Me a Message';
        }

        return ElevatedButton.icon(
          icon: Icon(unreadCount > 0 ? Icons.mark_email_unread : Icons.message),
          label: Text(
            buttonText,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            backgroundColor: unreadCount > 0 ? Colors.orange : null,
            foregroundColor: unreadCount > 0 ? Colors.white : null,
          ),
          onPressed: () async {
            if (unreadCount > 0) {
              await markProviderMessagesAsRead(user.uid);
            }
            onPressed();
          },
        );
      },
    );
  }
}

// Full-width message input widget that appears independently
class FullWidthMessageInput extends StatefulWidget {
  final User user;
  final String Function(DateTime) formatMessageTime;
  final VoidCallback onClose;

  const FullWidthMessageInput({
    super.key,
    required this.user,
    required this.formatMessageTime,
    required this.onClose,
  });

  @override
  State<FullWidthMessageInput> createState() => _FullWidthMessageInputState();
}

class _FullWidthMessageInputState extends State<FullWidthMessageInput> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _markProviderMessagesAsReadWithTimeLimit(
    DateTime currentTime,
  ) async {
    try {
      final cutoffTime = currentTime.subtract(const Duration(seconds: 1));

      final messagesQuery =
          await FirebaseFirestore.instance
              .collection('messages')
              .where('userId', isEqualTo: widget.user.uid)
              .where('fromAdmin', isEqualTo: true)
              .get();

      final batch = FirebaseFirestore.instance.batch();

      for (var doc in messagesQuery.docs) {
        final data = doc.data();

        if (data.containsKey('read') && data['read'] == true) {
          continue;
        }

        final timestamp = data['timestamp'];
        DateTime? messageTime;

        if (timestamp is Timestamp) {
          messageTime = timestamp.toDate();
        } else if (timestamp is String) {
          try {
            messageTime = DateTime.parse(timestamp);
          } catch (_) {}
        }

        if (messageTime != null && messageTime.isBefore(cutoffTime)) {
          batch.update(doc.reference, {'read': true});
        }
      }

      await batch.commit();
    } catch (e) {
      // Handle error silently
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MediaQuery.of(context).size.width - 32,
      margin: const EdgeInsets.symmetric(horizontal: 0.0),
      padding: const EdgeInsets.all(16.0),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.1),
            spreadRadius: 1,
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: 'Type your message...',
              hintText: 'Send a message to your provider',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: Colors.deepPurple,
                  width: 2,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            minLines: 2,
            maxLines: 4,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.grey.shade700,
                  side: BorderSide(color: Colors.grey.shade300),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                ),
                child: const Text('Cancel'),
                onPressed: () async {
                  await _markProviderMessagesAsReadWithTimeLimit(
                    DateTime.now(),
                  );
                  _controller.clear();
                  widget.onClose();
                },
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  elevation: 2,
                ),
                child: const Text('Send'),
                onPressed: () async {
                  final text = _controller.text.trim();
                  final now = DateTime.now();

                  await _markProviderMessagesAsReadWithTimeLimit(now);

                  if (text.isNotEmpty) {
                    await FirebaseFirestore.instance
                        .collection('messages')
                        .add({
                          'userId': widget.user.uid,
                          'timestamp': now.toIso8601String(),
                          'message': text,
                        });
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Message sent!'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  } else {
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

                  await FirebaseFirestore.instance
                      .collection('users')
                      .doc(widget.user.uid)
                      .set({
                        'nudge': 1,
                        'lastNudge': now.toIso8601String(),
                      }, SetOptions(merge: true));

                  _controller.clear();
                  widget.onClose();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.history, color: Colors.grey.shade600, size: 20),
              const SizedBox(width: 8),
              Text(
                'Message History',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: MediaQuery.of(context).size.height * 0.4,
            constraints: const BoxConstraints(
              minHeight: 200,
              maxHeight: 400,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade200),
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey.shade50,
            ),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: StreamBuilder<QuerySnapshot>(
                stream:
                    FirebaseFirestore.instance
                        .collection('messages')
                        .where('userId', isEqualTo: widget.user.uid)
                        .orderBy('timestamp', descending: true)
                        .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20.0),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return StreamBuilder<QuerySnapshot>(
                      stream:
                          FirebaseFirestore.instance
                              .collection('messages')
                              .where('userId', isEqualTo: widget.user.uid)
                              .snapshots(),
                      builder: (context, snap2) {
                        if (snap2.connectionState == ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (!snap2.hasData) {
                          return const Center(
                            child: Text(
                              'No messages found.',
                              style: TextStyle(color: Colors.grey),
                            ),
                          );
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
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(20.0),
                              child: Text(
                                'No messages yet. Start a conversation!',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          );
                        }
                        docs.sort((a, b) {
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

                          if (bTime == null && aTime == null) return 0;
                          if (bTime == null) return -1;
                          if (aTime == null) return 1;
                          return bTime.compareTo(aTime);
                        });
                        return ListView.builder(
                          reverse: true,
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            return _buildMessageBubble(docs[index]);
                          },
                        );
                      },
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(
                      child: Text(
                        'No messages found.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    );
                  }
                  final docs = snapshot.data!.docs;
                  if (docs.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20.0),
                        child: Text(
                          'No messages yet. Start a conversation!',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    reverse: true,
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      return _buildMessageBubble(docs[index]);
                    },
                  );
                },
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final msg = data['message'] ?? '';
    final ts = data['timestamp'] ?? '';

    // Robustly parse fromProvider field
    bool fromProvider = false;
    if (data.containsKey('fromAdmin')) {
      final raw = data['fromAdmin'];
      if (raw is bool) {
        fromProvider = raw;
      } else if (raw is String) {
        fromProvider = raw.toLowerCase() == 'true';
      } else if (raw is int) {
        fromProvider = raw == 1;
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

    final formatted = dt != null ? widget.formatMessageTime(dt) : ts.toString();

    if (fromProvider) {
      // Provider message: left-aligned, blue background
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.blue[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue, width: 0.5),
          ),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 14, color: Colors.black),
              children: [
                TextSpan(text: msg.isEmpty ? '(nudge)' : msg),
                TextSpan(
                  text: ' sent by Provider at $formatted',
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
          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.deepPurple[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.deepPurple, width: 0.5),
          ),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 14, color: Colors.black),
              children: [
                TextSpan(text: msg.isEmpty ? '(nudge)' : msg),
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
  }
}

// MessageInputWidget for user message input
class MessageInputWidget extends StatefulWidget {
  final User user;
  final Future<Map<String, dynamic>> Function(String) getUnreadMessageInfo;
  final Future<void> Function(String) markProviderMessagesAsRead;
  final String Function(DateTime) formatMessageTime;

  const MessageInputWidget({
    super.key,
    required this.user,
    required this.getUnreadMessageInfo,
    required this.markProviderMessagesAsRead,
    required this.formatMessageTime,
  });

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

  // Helper method to mark provider messages as read with time limit
  Future<void> _markProviderMessagesAsReadWithTimeLimit(
    DateTime currentTime,
  ) async {
    try {
      final cutoffTime = currentTime.subtract(const Duration(seconds: 1));

      final messagesQuery =
          await FirebaseFirestore.instance
              .collection('messages')
              .where('userId', isEqualTo: widget.user.uid)
              .where('fromAdmin', isEqualTo: true)
              .get();

      final batch = FirebaseFirestore.instance.batch();

      for (var doc in messagesQuery.docs) {
        final data = doc.data();

        // Skip if already read
        if (data.containsKey('read') && data['read'] == true) {
          continue;
        }

        // Check message timestamp
        final timestamp = data['timestamp'];
        DateTime? messageTime;

        if (timestamp is Timestamp) {
          messageTime = timestamp.toDate();
        } else if (timestamp is String) {
          try {
            messageTime = DateTime.parse(timestamp);
          } catch (_) {}
        }

        // Only mark as read if message was sent before the cutoff time
        if (messageTime != null && messageTime.isBefore(cutoffTime)) {
          batch.update(doc.reference, {'read': true});
        }
      }

      await batch.commit();
    } catch (e) {
      // Handle error silently
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> children = [];
    if (!showInput) {
      children.add(
        // Use StreamBuilder to check for unread messages in real-time
        StreamBuilder<QuerySnapshot>(
          stream:
              FirebaseFirestore.instance
                  .collection('messages')
                  .where('userId', isEqualTo: widget.user.uid)
                  .where('fromAdmin', isEqualTo: true)
                  .snapshots(),
          builder: (context, snapshot) {
            int unreadCount = 0;
            DateTime? latestTimestamp;

            if (snapshot.hasData) {
              final unreadMessages =
                  snapshot.data!.docs.where((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    // Consider unread if read field doesn't exist or is false
                    return !data.containsKey('read') || data['read'] != true;
                  }).toList();

              unreadCount = unreadMessages.length;

              // Find the latest unread message timestamp
              for (var doc in unreadMessages) {
                final data = doc.data() as Map<String, dynamic>;
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
                  if (latestTimestamp == null ||
                      messageTime.isAfter(latestTimestamp)) {
                    latestTimestamp = messageTime;
                  }
                }
              }
            }

            String buttonText;
            if (unreadCount > 0) {
              final timeText =
                  latestTimestamp != null
                      ? widget.formatMessageTime(latestTimestamp)
                      : 'recently';

              if (unreadCount == 1) {
                buttonText = '1 New message received ($timeText)';
              } else {
                buttonText = '$unreadCount New messages received ($timeText)';
              }
            } else {
              buttonText = 'Send Me a Message';
            }

            return ElevatedButton.icon(
              icon: Icon(
                unreadCount > 0 ? Icons.mark_email_unread : Icons.message,
              ),
              label: Text(
                buttonText,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 8,
                ),
                backgroundColor: unreadCount > 0 ? Colors.orange : null,
                foregroundColor: unreadCount > 0 ? Colors.white : null,
              ),
              onPressed: () async {
                // Mark messages as read when opening
                if (unreadCount > 0) {
                  await widget.markProviderMessagesAsRead(widget.user.uid);
                }
                setState(() {
                  showInput = true;
                });
              },
            );
          },
        ),
      );
    }
    if (showInput) {
      children.add(
        Container(
          width: MediaQuery.of(context).size.width - 32,
          margin: const EdgeInsets.symmetric(horizontal: 0.0, vertical: 8.0),
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.1),
                spreadRadius: 1,
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                decoration: InputDecoration(
                  labelText: 'Type your message...',
                  hintText: 'Send a message to your provider',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Colors.deepPurple,
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                minLines: 2,
                maxLines: 4,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey.shade700,
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                    child: const Text('Cancel'),
                    onPressed: () async {
                      // Mark provider messages as read (excluding those sent within 1 second)
                      await _markProviderMessagesAsReadWithTimeLimit(
                        DateTime.now(),
                      );
                      _reset();
                    },
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      elevation: 2,
                    ),
                    child: const Text('Send'),
                    onPressed: () async {
                      final text = _controller.text.trim();
                      final now = DateTime.now();

                      // Mark provider messages as read (excluding those sent within 1 second)
                      await _markProviderMessagesAsReadWithTimeLimit(now);

                      if (text.isNotEmpty) {
                        await FirebaseFirestore.instance
                            .collection('messages')
                            .add({
                              'userId': widget.user.uid,
                              'timestamp': now.toIso8601String(),
                              'message': text,
                            });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Message sent!'),
                            duration: Duration(seconds: 1),
                          ),
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
                ],
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.history, color: Colors.grey.shade600, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Message History',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                height: MediaQuery.of(context).size.height * 0.4,
                constraints: const BoxConstraints(
                  minHeight: 200,
                  maxHeight: 400,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade200),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey.shade50,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: StreamBuilder<QuerySnapshot>(
                    stream:
                        FirebaseFirestore.instance
                            .collection('messages')
                            .where('userId', isEqualTo: widget.user.uid)
                            .orderBy('timestamp', descending: true)
                            .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(20.0),
                            child: CircularProgressIndicator(),
                          ),
                        );
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
                              return const Center(
                                child: Text(
                                  'No messages found.',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              );
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
                              return const Center(
                                child: Text(
                                  'No messages sent yet.',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              );
                            }
                            docs.sort((a, b) {
                              dynamic ta =
                                  (a.data()
                                      as Map<String, dynamic>)['timestamp'];
                              dynamic tb =
                                  (b.data()
                                      as Map<String, dynamic>)['timestamp'];
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
                              itemBuilder:
                                  (context, idx) =>
                                      _buildMessageBubble(docs[idx]),
                            );
                          },
                        );
                      }
                      if (!snapshot.hasData) {
                        return const Center(
                          child: Text(
                            'No messages found.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        );
                      }
                      final docs = snapshot.data!.docs;
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text(
                            'No messages sent yet.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder:
                            (context, idx) => _buildMessageBubble(docs[idx]),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(children: children);
  }

  Widget _buildMessageBubble(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final msg = data['message'] ?? '';
    final ts = data['timestamp'] ?? '';

    // Robustly parse fromProvider field
    bool fromProvider = false;
    if (data.containsKey('fromAdmin')) {
      final raw = data['fromAdmin'];
      if (raw is bool) {
        fromProvider = raw;
      } else if (raw is String) {
        fromProvider = raw.toLowerCase() == 'true';
      } else if (raw is int) {
        fromProvider = raw == 1;
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

    if (fromProvider) {
      // Provider message: left-aligned, blue background
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.blue[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue, width: 0.5),
          ),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 14, color: Colors.black),
              children: [
                TextSpan(text: msg.isEmpty ? '(nudge)' : msg),
                TextSpan(
                  text: ' sent by Provider at $formatted',
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
          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.deepPurple[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.deepPurple, width: 0.5),
          ),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 14, color: Colors.black),
              children: [
                TextSpan(text: msg.isEmpty ? '(nudge)' : msg),
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
  }
}
