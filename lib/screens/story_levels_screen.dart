import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../services/user_progress_service.dart';
import '../widgets/custom_button.dart';
import '../widgets/math_background.dart';
import 'math_problem_screen.dart';

class StoryLevelsScreen extends StatefulWidget {
  const StoryLevelsScreen({
    super.key,
    this.progressUpdates,
    this.openStoryLevel,
  });

  final Stream<UserProgress>? progressUpdates;
  final Future<bool?> Function(int level)? openStoryLevel;

  @override
  State<StoryLevelsScreen> createState() => _StoryLevelsScreenState();
}

class _StoryLevelsScreenState extends State<StoryLevelsScreen> {
  Set<int> completedLevels = {};
  Set<int> provisionalCompletedLevels = {};
  Set<int> unlockedLevels = {1};
  StreamSubscription<UserProgress>? _progressSubscription;
  bool _accessReady = false;
  String? _accessError;
  int? expandedMainLevel; // Track which main level is expanded
  final Map<int, int> levelsPerMainLevel = {
    1: 20,
    2: 20,
    3: 20
  }; // Levels in each main level
  // Track the highest unlocked sublevel for each main level
  // All levels: progressive unlock (start with 1 available)
  Map<int, int> maxUnlockedSubLevel = {1: 1, 2: 1, 3: 1};

  @override
  void initState() {
    super.initState();
    unawaited(_initializeProgressAccess());
  }

  Future<void> _initializeProgressAccess() async {
    if (widget.progressUpdates != null) {
      _accessReady = true;
      _watchProgress();
      return;
    }

    try {
      final progress =
          await UserProgressService.getStoryProgressForCurrentSession(
        refreshFromServer: true,
      );
      if (!mounted) return;
      _accessReady = true;
      await _applyProgress(progress);
      _watchProgress();
    } catch (error, stackTrace) {
      debugPrint('Unable to verify Story Level access: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _accessError = error is WorksheetModuleAccessException
            ? error.message
            : 'Verify your student session online before opening Story Levels.';
      });
    }
  }

  void _watchProgress() {
    try {
      _progressSubscription = (widget.progressUpdates ??
              UserProgressService.watchCurrentUserProgress())
          .listen(
        (progress) => unawaited(_applyProgress(progress)),
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('Unable to watch Stage Selection progress: $error');
          debugPrintStack(stackTrace: stackTrace);
        },
      );
    } catch (error, stackTrace) {
      debugPrint('Unable to start Stage Selection progress updates: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _applyProgress(UserProgress progress) async {
    if (!mounted) return;
    final UserProgress visibleProgress;
    try {
      visibleProgress = widget.progressUpdates != null
          ? progress
          : await UserProgressService.applyPendingOfflineStoryProgress(
              progress);
    } catch (error, stackTrace) {
      debugPrint('Unable to apply provisional Story progress: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted && error is WorksheetModuleAccessException) {
        setState(() {
          _accessReady = false;
          _accessError = error.message;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      completedLevels = visibleProgress.completedLevels.toSet();
      provisionalCompletedLevels =
          visibleProgress.provisionalCompletedLevels.toSet();
      final unlockedCount = visibleProgress.provisionalUnlockedLevels ??
          visibleProgress.unlockedLevels;
      unlockedLevels = {for (int i = 1; i <= unlockedCount; i++) i};
      final provisionalSublevels =
          visibleProgress.provisionalMaxUnlockedSubLevel;
      maxUnlockedSubLevel = {
        1: provisionalSublevels[1] ??
            visibleProgress.maxUnlockedSubLevel[1] ??
            1,
        2: provisionalSublevels[2] ??
            visibleProgress.maxUnlockedSubLevel[2] ??
            1,
        3: provisionalSublevels[3] ??
            visibleProgress.maxUnlockedSubLevel[3] ??
            1,
      };
    });
  }

  @override
  void dispose() {
    unawaited(_progressSubscription?.cancel());
    super.dispose();
  }

  void _applyConfirmedCompletion(int globalLevelId, int mainLevel) {
    final displayNumber = globalLevelId % 20 == 0 ? 20 : globalLevelId % 20;
    final nextSubLevel = displayNumber + 1;

    setState(() {
      completedLevels.add(globalLevelId);
      if (nextSubLevel <= levelsPerMainLevel[mainLevel]!) {
        maxUnlockedSubLevel[mainLevel] = nextSubLevel;
      }
      if (mainLevel == 1 && displayNumber == levelsPerMainLevel[1]) {
        unlockedLevels.add(2);
      }
      if (mainLevel == 2 && displayNumber == levelsPerMainLevel[2]) {
        unlockedLevels.add(3);
      }
    });
  }

  Future<bool?> _openStoryLevel(int level) async {
    final openStoryLevel = widget.openStoryLevel;
    if (openStoryLevel != null) return openStoryLevel(level);

    return Navigator.push<bool>(
      context,
      PageRouteBuilder<bool>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            MathProblemScreen(level: level),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MathBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                  child: Container(color: Colors.transparent),
                ),
              ),
              Column(
                children: [
                  const SizedBox(height: 20),
                  const Text(
                    'Choose a Stage',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 30),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          // Main Level Buttons - Always show all 3
                          Center(
                            child: Column(
                              children: () {
                                final visibleLevels = expandedMainLevel == null
                                    ? [1, 2, 3]
                                    : [expandedMainLevel!];
                                return visibleLevels.map((mainLevel) {
                                  bool isUnlocked = mainLevel == 1 ||
                                      (mainLevel == 2 &&
                                          unlockedLevels.contains(2)) ||
                                      (mainLevel == 3 &&
                                          unlockedLevels.contains(3));
                                  bool isExpanded =
                                      expandedMainLevel == mainLevel;

                                  return mainLevelButton(
                                      mainLevel, isUnlocked, isExpanded);
                                }).toList();
                              }(),
                            ),
                          ),

                          const SizedBox(height: 30),

                          // Sub-levels for expanded main level
                          if (expandedMainLevel != null)
                            Column(
                              children: [
                                Text(
                                  'Stage $expandedMainLevel - Choose a Substage',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Center(
                                  child: Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 12,
                                    runSpacing: 12,
                                    children: List.generate(
                                      levelsPerMainLevel[expandedMainLevel]!,
                                      (index) {
                                        int subLevel = index + 1;
                                        int globalLevelId =
                                            (expandedMainLevel! - 1) * 20 +
                                                subLevel;
                                        return sublevelCard(
                                            globalLevelId, expandedMainLevel!);
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: CustomButton(
                      text: 'Back',
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
              if (!_accessReady) ...[
                const Positioned.fill(
                  child: ModalBarrier(
                    dismissible: false,
                    color: Colors.black12,
                  ),
                ),
                Center(
                  child: _accessError == null
                      ? const CircularProgressIndicator()
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _accessError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Main Level Button (Level 1, Level 2, Level 3) - Styled like home screen menu
  Widget mainLevelButton(int mainLevel, bool isUnlocked, bool isExpanded) {
    String getUnlockMessage(int level) {
      if (level == 2) {
        return 'Complete Stage 1';
      } else if (level == 3) {
        return 'Complete Stage 2';
      }
      return '';
    }

    return GestureDetector(
      onTap: isUnlocked
          ? () {
              setState(() {
                expandedMainLevel = isExpanded ? null : mainLevel;
              });
            }
          : null,
      child: Container(
        width: (MediaQuery.sizeOf(context).width -
                MediaQuery.paddingOf(context).horizontal -
                40)
            .clamp(0.0, 500.0),
        height: 60,
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: isUnlocked ? const Color(0xFFF1D0AD) : Colors.grey[400],
          borderRadius: BorderRadius.circular(15),
          boxShadow: isUnlocked
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 5,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
          border: isExpanded
              ? Border.all(color: const Color(0xFF4CAF50), width: 3)
              : Border.all(color: Colors.transparent, width: 3),
        ),
        child: Row(
          children: [
            Icon(
              isUnlocked ? Icons.book : Icons.lock,
              size: 40,
              color: isUnlocked ? Colors.black87 : Colors.white,
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Stage $mainLevel',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  if (!isUnlocked)
                    Text(
                      getUnlockMessage(mainLevel),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black,
                      ),
                    ),
                ],
              ),
            ),
            if (isUnlocked)
              Icon(
                isExpanded ? Icons.expand_less : Icons.expand_more,
                color: Colors.white70,
                size: 28,
              ),
          ],
        ),
      ),
    );
  }

  // Sub-level Card for selected main level
  Widget sublevelCard(int globalLevelId, int mainLevel) {
    bool isCompleted = completedLevels.contains(globalLevelId) ||
        provisionalCompletedLevels.contains(globalLevelId);
    int displayNumber = globalLevelId % 20 == 0 ? 20 : globalLevelId % 20;

    // All levels: progressive unlock based on maxUnlockedSubLevel
    bool isUnlocked = displayNumber <= maxUnlockedSubLevel[mainLevel]!;

    return GestureDetector(
      onTap: isUnlocked
          ? () async {
              final result = await _openStoryLevel(globalLevelId);

              if (result == true && mounted) {
                if (widget.progressUpdates != null) {
                  _applyConfirmedCompletion(globalLevelId, mainLevel);
                  return;
                }
                try {
                  final progress = await UserProgressService
                      .getStoryProgressForCurrentSession();
                  await _applyProgress(progress);
                } catch (error, stackTrace) {
                  debugPrint('Unable to refresh Story progress: $error');
                  debugPrintStack(stackTrace: stackTrace);
                }
              }
            }
          : null,
      child: Container(
        width: 65,
        height: 65,
        decoration: BoxDecoration(
          color: isCompleted
              ? const Color(0xFF4CAF50)
              : (isUnlocked ? const Color(0xFF2196F3) : Colors.grey),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 4)
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isCompleted
                  ? Icons.check_circle
                  : (isUnlocked ? Icons.brightness_1 : Icons.lock),
              color: Colors.white,
              size: 24,
            ),
            const SizedBox(height: 3),
            Text(
              '$displayNumber',
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
