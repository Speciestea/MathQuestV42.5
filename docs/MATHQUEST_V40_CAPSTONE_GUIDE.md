# MathQuest V40 Capstone and Release Guide

## Project status

This guide describes the checked-in MathQuest V40 code and the validation
performed for the final sprint. It is not evidence of production deployment,
user acceptance testing, or real-device testing.

- Baseline: `feature/partial-offline-mode`, commit `d4b4bdd`.
- Online gameplay and the existing randomized question generators remain
  unchanged by this sprint.
- Bounded offline Game Mode completion synchronization is implemented.
- Standalone offline Story question answers remain provisional-only.
- No production Firebase configuration or data was changed.

## Feature inventory

### Students

- Register and sign in; new accounts follow the account approval flow.
- Study mathematics modules and worked examples.
- Play Story Levels and the associated Game Mode.
- Complete Classroom Quest activities.
- Use Practice Mode for personal practice; it does not submit official points.
- View profile information, badges, and the leaderboard.
- Access previously unlocked material offline when the student authorization
  and progress were verified and cached on that device.

### Teachers and administrators

- Approved teachers can view student analytics and Classroom Quest history.
- Administrators can review student registrations, approve or reject accounts,
  approve teacher accounts, clear device sessions, and access account-support
  actions.
- Access is role- and session-controlled; availability depends on Firebase
  authorization and the configured Firestore Rules.

## Architecture

| Area | Main components |
|---|---|
| Flutter UI and session routing | `lib/main.dart`, `lib/screens/` |
| Lessons and question generation | `lib/worksheet_lesson_data.dart`, `lib/game/npc_question.dart` |
| Flame Game Mode | `lib/game/math_world_game.dart`, `lib/game/player.dart`, `lib/screens/number_pickup_game_screen.dart` |
| Authentication and device sessions | `lib/services/auth_service.dart`, `lib/services/verified_display_cache.dart` |
| Official progress and leaderboard | `lib/services/user_progress_service.dart`, `lib/services/leaderboard_service.dart`, `firestore.rules` |
| Durable offline events | `lib/services/offline_progress_store.dart`, `lib/services/offline_progress_database_io.dart`, `lib/services/offline_progress_database_web.dart` |
| Reconnection and bounded sync | `lib/services/offline_story_sync_coordinator.dart`, `lib/services/offline_story_completion_claim_service.dart` |
| Teacher reporting | `lib/services/teacher_analytics_service.dart`, `lib/screens/teacher_analytics_screen.dart` |

On native platforms the offline event store uses Sembast IO. On web it uses
Sembast Web and IndexedDB. Events include an owner UID, event ID, schema
version, sequence, and dependency data. They are local records, not official
Firebase progress until a server-accepted synchronization is confirmed.

## Online workflow

1. A student signs in and their account and active device session are checked.
2. The student opens lessons, Story Levels, Game Mode, or other available
   activities.
3. Online progress and awards are written through the existing Firebase
   services and Firestore Rules.
4. Game Mode completion updates student progress and the leaderboard using
   transaction-based award logic. Existing online answer, score, and progression
   behavior is retained.

## Offline workflow and synchronization

1. While online, the student must establish a verified student session and
   cache the progress needed for offline access.
2. Offline access is scoped to the same UID, device, session, and cached
   unlocks. It does not grant access to new levels.
3. Offline Game Mode continues to use the existing randomized gameplay. Local
   answers and completions are provisional events; no Firestore write is
   required to continue playing.
4. On a connectivity change or app resume, the coordinator revalidates the
   Firebase student authorization and active session. Network availability by
   itself is not treated as proof that Firebase is reachable.
5. A bounded Game Mode completion claim is reconciled transactionally against
   current official progress. Firestore Rules validate authorization,
   progression, allowed score bounds, and one-time reward conditions.
6. Local events are acknowledged only after the submitter receives a matching
   server confirmation. Interrupted transactions and retries are protected by
   the existing idempotent award record.
7. If the UID/session changes, authorization is revoked, or current progress
   conflicts with a claim, it is not promoted as official progress. Rejected
   events are not automatically deleted.

Standalone Story level-question answers and their existing 10-point awards
remain provisional-only. The attempted atomic Rules validation exceeded
Firestore's expression-evaluation limit. Splitting the answer and reward
writes or weakening authorization is not an approved workaround.

Offline Practice Mode is personal practice and does not affect official
leaderboard points or progress.

## Student quick-start manual

1. Register with the required account details and wait for approval if the
   account is pending.
2. Sign in while connected so the app can verify the account and active device
   session.
3. From Home, choose a module, Story Level, Classroom Quest, or Practice Mode.
4. In Story Levels, follow the displayed unlock requirements. Game Mode is
   available only when that level is unlocked.
5. For offline use, open the desired material while online first. Offline
   access is limited to previously verified and cached authorization/progress.
6. After offline Game Mode play, reconnect with the same account and allow the
   app to resume synchronization. Confirm official progress after the server
   accepts it.
7. Do not treat offline Story question answers as official leaderboard points;
   those answers remain provisional for this release.

Practice Mode scores are for personal practice and are not submitted to the
official leaderboard.

## Functional test cases and evidence

| Area | Coverage | Evidence/status |
|---|---|---|
| Authorization and UID binding | Approved-student access, device/session binding, account changes | Flutter authorization and offline module access tests passed |
| Durable offline events | Insert, retry/idempotency, UID isolation, persistence behavior | Flutter offline store and progress service tests passed |
| Synchronization coordinator | Sequence/dependency ordering, confirmation-gated acknowledgement, session changes | Flutter coordinator tests passed |
| Game Mode Firestore Rules | Approved ownership, active session, progression, score bounds, one-time reward, retries | Firestore Emulator suite passed 37 printed checks |
| Registration flow | Sequential IDs, concurrent uniqueness, idempotent retry, preservation of existing accounts | Auth/Firestore Emulator flow passed its consolidated scenario |
| Full Flutter VM suite | Application unit/widget regressions | `flutter test`: 222 passed, 0 failed |
| Static analysis | Dart/Flutter diagnostics | `flutter analyze`: no issues |
| Web IndexedDB persistence | Close/reopen and retrieve stored event in a browser | Not verified: the Chrome test host did not load the test; see release checklist |
| Real-device offline integration | Offline play, reconnect, account switching, revoked session | Not performed |

`npm run test` runs the Firestore Rules suite followed by the registration-flow
emulator suite. Emulator denials emitted by negative authorization cases are
expected assertions; the command completed successfully. Emulator results do
not substitute for testing against a physical device or production Firebase.

The web-specific test is marked for browser execution so the VM suite does not
try to open IndexedDB through the native `path_provider` implementation. The
attempted `flutter test --platform chrome` runs remained at test loading; the
Flutter web test host logged a `GET /` handler error (`Bad state: No element`).
Therefore, the 222-test VM result does not include verified IndexedDB browser
coverage.

## Security and data-integrity controls

- Firestore operations use the authenticated UID and existing student approval
  and active-session checks.
- Offline events are locally UID-scoped and use stable IDs, schema versions,
  ordering, and dependencies.
- Synchronization verifies that the same session is still current before
  submission and acknowledgement.
- Completion and one-time reward changes are reconciled transactionally with
  current user progress and leaderboard data.
- Existing Firestore Rules restrict official progress, score bounds, allowed
  progression, and duplicate awards; emulator tests exercise allowed and
  denied cases.
- Local timestamps, answers, claim IDs, and scores are client-generated and
  are not trusted evidence of actual play.
- Rules can validate the bounded claim's structure and consistency, but cannot
  prove that randomized questions were legitimately presented and answered.
  Official offline Game Mode synchronization therefore retains this documented
  client-claim trust limitation.
- Standalone Story question answer/reward sync remains disabled/provisional;
  no Rule was weakened to force acceptance.

## Firebase Spark Free and usage review

The bounded synchronization path uses Firebase Auth and Firestore only; this
sprint adds no Cloud Functions, Cloud Run, paid backend, or new infrastructure.
The connectivity coordinator reacts to connectivity changes and app resume; it
does not poll Firestore on a timer. Offline answer attempts are not uploaded
one-by-one; the bounded completion claim is reconciled as a transaction.

No runtime read/write optimization was applied: emulator-only evidence did not
identify a safe, measurable reduction that would justify changing the existing
authorization or transaction flow. The emulator does not measure production
Spark quota consumption. Review actual Firebase usage before release.

## Screenshot checklist

Capture only with test accounts or consented, redacted data:

- Registration and pending-approval state.
- Student Home and module/lesson view.
- Story Level unlock state and Game Mode entry.
- A randomly generated Game Mode question and its score/health HUD.
- Practice Mode's personal-practice disclaimer.
- Leaderboard and badges.
- Teacher analytics and Classroom Quest history.
- Administrator roster approval/rejection actions.
- Offline Game Mode before and after reconnection, clearly labeling
  provisional versus server-confirmed progress.
- A network/session rejection or retry state, if available in the release build.

Do not present a screenshot of provisional Story question progress as an
official award or synced leaderboard result.

## Defense demonstration checklist

1. Explain the student, teacher, and administrator roles.
2. Demonstrate a lesson and show that question generation remains randomized
   and progression remains difficulty-based.
3. Demonstrate online Game Mode scoring and the corresponding official
   progression path.
4. Show the Offline Practice disclaimer and distinguish practice from official
   scoring.
5. Demonstrate the bounded offline Game Mode flow only after the browser and
   real-device items below have been verified.
6. Show Firestore Emulator Rules tests, including authorization denials and
   duplicate-reward protection.
7. Explain that Firestore Rules cannot prove the authenticity of
   client-generated randomized gameplay claims.
8. State clearly that standalone Story question synchronization remains
   provisional-only.
9. Present test results exactly as recorded; do not imply production or
   real-device testing.

## Release-readiness checklist

- [x] Preserve original randomized generation, difficulty progression, scoring,
  and online gameplay in this sprint.
- [x] Keep standalone Story question synchronization provisional-only.
- [x] Pass Flutter analysis and the full Flutter VM regression suite.
- [x] Pass Firestore Rules and registration-flow emulator suites.
- [ ] Run and pass the browser IndexedDB persistence test using a working
  Flutter web test host.
- [ ] Test offline Game Mode, reconnect retries, logout/account switching,
  revoked sessions, and official progress reconciliation on a real device.
- [ ] Review Firebase Spark usage using the target project's actual usage
  metrics; no production configuration was accessed in this sprint.
- [ ] Complete the screenshot and defense checklists using verified results.
- [ ] Obtain approval before any commit, push, deployment, or production Rules
  change.

**Verdict: Not ready for release.** The Flutter VM and emulator suites pass,
but browser persistence and real-device offline/reconnection integration remain
unverified. Do not claim full offline synchronization or official Story
question awards.
