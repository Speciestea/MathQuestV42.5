import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/user_account.dart';
import '../services/auth_service.dart';
import '../services/leaderboard_service.dart';
import '../services/user_progress_service.dart';
import '../utils/display_text.dart';
import '../widgets/math_background.dart';
import '../widgets/student_profile_picture.dart';
import 'login_screen.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  List<UserAccount> accounts = [];
  Map<String, UserProgress> progressByEmail = {};
  final Set<String> _deletedAccountUids = {};
  StreamSubscription<List<UserAccount>>? _accountsSubscription;
  int _accountRosterRevision = 0;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _accountsSubscription = AuthService.watchAccounts().listen(
      (loaded) {
        _accountRosterRevision++;
        final visibleAccounts = loaded
            .where((account) => !_deletedAccountUids.contains(account.uid))
            .toList();
        if (mounted) setState(() => accounts = visibleAccounts);
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Unable to watch admin account roster: $error');
        debugPrintStack(stackTrace: stackTrace);
        if (!mounted) return;
        setState(() => isLoading = false);
      },
    );
    _loadAccounts();
  }

  Future<bool> _loadAccounts({bool forceServer = false}) async {
    if (mounted) setState(() => isLoading = true);
    final rosterRevision = _accountRosterRevision;
    try {
      final loaded = (await AuthService.loadAccounts(forceServer: forceServer))
          .where((account) => !_deletedAccountUids.contains(account.uid))
          .toList();
      final progressEntries = await Future.wait(loaded.map((account) async {
        final progress =
            await UserProgressService.getProgressForUid(account.uid);
        return MapEntry(account.email, progress);
      }));
      if (!mounted) return false;
      setState(() {
        if (_accountRosterRevision == rosterRevision) accounts = loaded;
        progressByEmail = Map.fromEntries(progressEntries);
        isLoading = false;
      });
      return true;
    } catch (error, stackTrace) {
      debugPrint('Unable to load admin account roster: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return false;
      setState(() => isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load student registrations. Retry.'),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
  }

  @override
  void dispose() {
    final subscription = _accountsSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  Future<void> _approveAccount(UserAccount account) async {
    try {
      await AuthService.approveStudentAccount(account.uid);
      var leaderboardInitialized = true;
      try {
        await LeaderboardService.initializeApprovedStudentEntry(account.uid);
      } catch (error, stackTrace) {
        debugPrint(
            'Unable to initialize approved student leaderboard entry: $error');
        debugPrintStack(stackTrace: stackTrace);
        leaderboardInitialized = false;
      }
      final rosterLoaded = await _loadAccounts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !rosterLoaded
                ? 'Student approved, but the account list could not be refreshed.'
                : leaderboardInitialized
                    ? 'Student approved and added to the leaderboard.'
                    : 'Student approved, but leaderboard record creation failed. '
                        'Check the connection and administrator permissions.',
          ),
          backgroundColor: rosterLoaded && leaderboardInitialized
              ? Colors.green
              : Colors.red,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to approve student account ${account.uid}: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Could not approve this student. Check access and retry.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _rejectAccount(UserAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reject Registration?'),
        content: Text(
          'Reject ${account.name.isEmpty ? account.email : account.name}\'s registration?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await AuthService.rejectStudentAccount(account.uid);
      final rosterLoaded = await _loadAccounts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rosterLoaded
                ? 'Student registration rejected.'
                : 'Student rejected, but the account list could not be refreshed.',
          ),
          backgroundColor: rosterLoaded ? Colors.orange : Colors.red,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to reject student account ${account.uid}: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Could not reject this student. Check access and retry.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _approveAsTeacher(UserAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Approve as Teacher?'),
        content: Text(
          'This will change ${account.name.isEmpty ? account.email : account.name} '
          'to an approved Teacher Account. They will keep their existing login '
          'credentials and account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Approve as Teacher'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await AuthService.approveAccountAsTeacher(account.uid);
      await _loadAccounts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${account.name.isEmpty ? account.email : account.name} '
            'is now an approved teacher.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } on FirebaseFunctionsException catch (error, stackTrace) {
      debugPrint(
        'Unable to approve account ${account.uid} as teacher '
        '(${error.code}): ${error.message}',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.code == 'permission-denied'
                ? 'Only an authorized admin can approve teachers.'
                : 'Could not approve this account as a teacher '
                    '(${error.code}): ${error.message ?? 'No server detail provided.'}',
          ),
          backgroundColor: Colors.red,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to approve account ${account.uid} as teacher: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not approve this account as a teacher. Retry.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteAccount(UserAccount account) async {
    try {
      await AuthService.deleteAccount(account);
      _deletedAccountUids.add(account.uid);
      if (mounted) {
        setState(() {
          accounts.removeWhere((loaded) => loaded.uid == account.uid);
          progressByEmail.remove(account.email);
        });
      }
      final rosterLoaded = await _loadAccounts(forceServer: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rosterLoaded
                ? 'Account deleted.'
                : 'Account deleted, but the account list could not be refreshed.',
          ),
          backgroundColor: rosterLoaded ? Colors.green : Colors.orange,
        ),
      );
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Unable to delete account ${account.uid} '
        '(${error.code}): ${error.message}',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not delete the account (${error.code}): '
            '${error.message ?? 'Firestore rejected the delete request.'}',
          ),
          backgroundColor: Colors.red,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to delete account ${account.uid}: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not delete the account: $error'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _clearLoginSession(UserAccount account) async {
    try {
      await AuthService.clearAccountLoginSession(account.uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cleared ${account.name.isEmpty ? account.email : account.name}\'s device session.',
          ),
        ),
      );
    } on FirebaseFunctionsException catch (error, stackTrace) {
      debugPrint('Unable to clear account device session: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not clear the device session (${error.code}).'),
          backgroundColor: Colors.red,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to clear account device session: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not clear the device session. Please retry.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _showPasswordRecoveryHelp(UserAccount account) async {
    var identityVerified = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('Reset Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Student: ${account.name.isEmpty ? account.email : account.name} (${account.email})',
              ),
              const SizedBox(height: 12),
              const Text(
                'Before helping, verify the student’s identity using your school’s established procedure. This screen cannot change another person’s Firebase password.',
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: identityVerified,
                onChanged: (value) => setDialogState(
                  () => identityVerified = value ?? false,
                ),
                title: const Text(
                  'I verified this student in person using school procedure.',
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: identityVerified
                  ? () => Navigator.of(dialogContext).pop(true)
                  : null,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    var sendingResetLink = false;
    String? resetRequestError;
    final resetRequested = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('Send Password Reset Link?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Student: ${account.name.isEmpty ? account.email : account.name}',
              ),
              Text('Registered email: ${account.email}'),
              const SizedBox(height: 12),
              const Text(
                'Firebase will send a reset link to this email if the request is accepted. The student must open the email and finish resetting the password. This action does not change the password now.',
              ),
              if (resetRequestError != null) ...[
                const SizedBox(height: 12),
                Text(
                  resetRequestError!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: sendingResetLink
                  ? null
                  : () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: sendingResetLink
                  ? null
                  : () async {
                      setDialogState(() {
                        sendingResetLink = true;
                        resetRequestError = null;
                      });
                      try {
                        await AuthService.sendStudentPasswordResetEmail(
                          studentUid: account.uid,
                          registeredEmail: account.email,
                        );
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop(true);
                        }
                      } catch (error, stackTrace) {
                        debugPrint(
                          'Unable to request student password reset email: '
                          'studentUid=${account.uid}, '
                          'errorType=${error.runtimeType}, error=$error.',
                        );
                        debugPrintStack(stackTrace: stackTrace);
                        if (!dialogContext.mounted) return;
                        setDialogState(() {
                          sendingResetLink = false;
                          resetRequestError =
                              _passwordResetRequestErrorMessage(error);
                        });
                      }
                    },
              child: Text(
                sendingResetLink ? 'Sending...' : 'Send Password Reset Link',
              ),
            ),
          ],
        ),
      ),
    );
    if (resetRequested == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Firebase accepted a password reset email request for ${account.email}. The student must use the link to set a new password.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  String _passwordResetRequestErrorMessage(Object error) {
    if (error is FirebaseAuthException) {
      return switch (error.code) {
        'too-many-requests' =>
          'Too many reset requests were made. Please wait before trying again.',
        'invalid-email' =>
          'The registered email address is invalid. Check the student account details.',
        'user-not-found' =>
          'Firebase could not find an account for this email. Check the student account details.',
        'network-request-failed' =>
          'Could not connect to Firebase. Check the connection and try again.',
        'operation-not-allowed' =>
          'Password reset email is not enabled for this Firebase project. Ask the Firebase administrator to enable it.',
        _ =>
          'Firebase could not accept the password reset email request (${error.code}). Please try again later.',
      };
    }
    if (error is StateError) return error.message;
    if (error is FirebaseException) {
      return switch (error.code) {
        'permission-denied' =>
          'Your administrator session could not be verified. Sign in again and retry.',
        'unavailable' ||
        'deadline-exceeded' =>
          'Could not connect to Firebase. Check the connection and try again.',
        _ =>
          'Could not verify the student account (${error.code}). Please retry.',
      };
    }
    return 'Could not request the password reset email. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final pending = UserAccount.sortAccountsByDisplayName(
        accounts.where((a) => a.isPending));
    final approvedStudents = UserAccount.sortAccountsByDisplayName(
      accounts.where((a) => !a.isAdmin && a.isApproved),
    );

    final media = MediaQuery.of(context);
    final screenHeight = media.size.height;
    final isSmall = media.size.width < 600; // treat <600px as mobile

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF8B5E3C),
        title: const Text(
          'Admin Dashboard',
          style: TextStyle(color: Colors.black),
        ),
        actions: [
          IconButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              final messenger = ScaffoldMessenger.maybeOf(context);

              try {
                await AuthService.signOut();
                if (!mounted) return;
                await navigator.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              } catch (error, stackTrace) {
                debugPrint('Unable to sign out admin session: $error');
                debugPrintStack(stackTrace: stackTrace);
                if (!mounted) return;
                messenger?.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Could not release this device session. Check your connection and try again.',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Fixed background
          Positioned.fill(
            child: IgnorePointer(
              child: MathBackground(
                child: SizedBox.expand(
                  child: Container(
                    color: Colors.transparent,
                  ),
                ),
              ),
            ),
          ),
          // Scrollable content on top — ensure it fills the viewport
          isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minHeight: screenHeight - kToolbarHeight),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: isSmall ? 12.0 : 24.0, vertical: 16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pending Student Signups',
                            style: TextStyle(
                              fontSize: isSmall ? 20 : 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (pending.isEmpty)
                            Text('No pending signups.',
                                style: TextStyle(color: Colors.black))
                          else
                            ...pending.map(_buildAccountCard),
                          const SizedBox(height: 24),
                          Text(
                            'Approved Students',
                            style: TextStyle(
                              fontSize: isSmall ? 20 : 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (approvedStudents.isEmpty)
                            Text('No approved student accounts yet.',
                                style: TextStyle(color: Colors.black))
                          else
                            ...approvedStudents.map(_buildAccountCard),
                          // add some spacing at the bottom so last card isn't flush to edge
                          SizedBox(height: isSmall ? 24 : 48),
                        ],
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(UserAccount account) {
    final isAdmin = account.isAdmin;
    return GestureDetector(
      onTap: () => _showAccountDetails(account),
      child: Card(
        color: const Color(0xFFF1D0AD),
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!isAdmin) ...[
                account.role.toLowerCase() == 'student'
                    ? StudentProfilePicture(
                        key: ValueKey(account.uid),
                        uid: account.uid,
                        profilePhotoUrl: account.profilePhotoUrl,
                        character: account.character,
                      )
                    : CircleAvatar(
                        radius: 25,
                        backgroundColor: const Color(0xFFD09F5C),
                        backgroundImage: AssetImage(
                          UserAccount.isCharacterProfileImageAsset(
                            account.profilePhotoUrl,
                          )
                              ? account.profilePhotoUrl
                              : UserAccount.profileImageAssetPathForCharacter(
                                  account.character,
                                ),
                        ),
                      ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.name.isNotEmpty ? account.name : account.email,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      account.email,
                      style: const TextStyle(color: Colors.black87),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    if (!isAdmin)
                      Text(
                        'Progress: ${progressByEmail[account.email]?.completedCount ?? 0} stages completed • Highest Stage ${progressByEmail[account.email]?.highestCompletedLevel ?? 0}',
                        style: const TextStyle(color: Colors.black87),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (!isAdmin)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: 'Delete account',
                  onPressed: () => _deleteAccount(account),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAccountDetails(UserAccount account) {
    final isAdmin = account.isAdmin;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(account.name.isNotEmpty ? account.name : account.email),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height -
                      MediaQuery.paddingOf(context).vertical -
                      MediaQuery.viewInsetsOf(context).vertical -
                      160)
                  .clamp(0.0, double.infinity),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (account.role.toLowerCase() == 'student') ...[
                    Center(
                      child: StudentProfilePicture(
                        key: ValueKey(account.uid),
                        uid: account.uid,
                        profilePhotoUrl: account.profilePhotoUrl,
                        character: account.character,
                        size: 72,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text('Email: ${account.email}'),
                  Text('Role: ${displayStatusLabel(account.role)}'),
                  Text('Status: ${displayStatusLabel(account.status)}'),
                  if (account.studentNo.isNotEmpty)
                    Text('Student No.: ${account.studentNo}'),
                  if (account.address.isNotEmpty)
                    Text('Address: ${account.address}'),
                  if (!isAdmin) ...[
                    const SizedBox(height: 8),
                    Text(
                        'Completed Stages: ${progressByEmail[account.email]?.completedCount ?? 0}'),
                    Text(
                        'Highest Completed Stage: ${progressByEmail[account.email]?.highestCompletedLevel ?? 0}'),
                    Text(
                        'Unlocked Chapters: ${progressByEmail[account.email]?.unlockedLevels ?? 1}'),
                    Text(
                        'Quest Attempts: ${progressByEmail[account.email]?.questAttempts ?? 0}'),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (account.role.toLowerCase() == 'student')
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              _showPasswordRecoveryHelp(account);
                            },
                            child: const Text('Reset Password'),
                          ),
                        if (account.role.toLowerCase() == 'student')
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              _approveAsTeacher(account);
                            },
                            child: const Text('Approve as Teacher'),
                          ),
                        if (account.isPending && !isAdmin)
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              _approveAccount(account);
                            },
                            child: const Text('Approve'),
                          ),
                        if (account.isPending && !isAdmin)
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              _rejectAccount(account);
                            },
                            child: const Text(
                              'Reject',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        if (!isAdmin)
                          TextButton(
                            onPressed: () async {
                              Navigator.of(context).pop();
                              final confirmed = await showDialog<bool>(
                                context: this.context,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text('Clear Device Session?'),
                                  content: Text(
                                    'This will sign out ${account.name.isEmpty ? account.email : account.name} from the current device and let them sign in again.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(dialogContext)
                                              .pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(dialogContext).pop(true),
                                      child: const Text('Clear Session'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                await _clearLoginSession(account);
                              }
                            },
                            child: const Text('Clear Device Session'),
                          ),
                        if (!isAdmin)
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              _deleteAccount(account);
                            },
                            child: const Text('Delete',
                                style: TextStyle(color: Colors.red)),
                          ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
