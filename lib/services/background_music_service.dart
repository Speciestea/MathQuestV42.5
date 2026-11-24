import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

class BackgroundMusicService {
  BackgroundMusicService._();

  static final BackgroundMusicService instance = BackgroundMusicService._();

  AudioPlayer? _player;
  Future<void>? _initialization;
  Future<void> _playbackUpdate = Future<void>.value();
  int _gameModeCount = 0;
  bool _isStarted = false;
  bool _isReady = false;
  bool _isMusicEnabled = true;
  bool _isForeground = true;
  bool _isPlaybackRequested = false;
  bool _isEligibleStudent = false;
  final ValueNotifier<bool> _musicEnabled = ValueNotifier<bool>(true);

  ValueListenable<bool> get musicEnabled => _musicEnabled;
  bool get isMusicEnabled => _isMusicEnabled;

  @visibleForTesting
  static bool isMusicEligibleForProfile({
    required String? role,
    required String? status,
  }) =>
      role?.trim().toLowerCase() == 'student' &&
      status?.trim().toLowerCase() == 'approved';

  Future<void> updateAccountProfile({
    required String? role,
    required String? status,
  }) async {
    _isEligibleStudent =
        isMusicEligibleForProfile(role: role, status: status);
    await _syncPlayback();
  }

  Future<void> start() {
    _isStarted = true;
    final existingPlayer = _player;
    if (existingPlayer != null) {
      return (_initialization ?? Future<void>.value()).then((_) {
        return _syncPlayback();
      });
    }

    late final AudioPlayer player;
    try {
      player = AudioPlayer();
    } catch (error, stackTrace) {
      _isStarted = false;
      _logAudioError(
        'create application background music player',
        error,
        stackTrace,
      );
      return Future<void>.value();
    }
    _player = player;
    _initialization = _initialize(player);
    return _initialization!;
  }

  Future<void> _initialize(AudioPlayer player) async {
    try {
      await player.setAsset('assets/music/BG_music.mp3');
      await player.setLoopMode(LoopMode.one);
      await player.setVolume(0.25);
      if (!identical(_player, player)) return;
      _isReady = true;
      await _syncPlayback();
    } catch (error, stackTrace) {
      _logAudioError(
          'initialize application background music', error, stackTrace);
    }
  }

  Future<void> enterGameMode() async {
    _gameModeCount++;
    await _syncPlayback();
  }

  Future<void> exitGameMode() async {
    if (_gameModeCount > 0) _gameModeCount--;
    await _syncPlayback();
  }

  Future<void> setMusicEnabled(bool enabled) async {
    _isMusicEnabled = enabled;
    _musicEnabled.value = enabled;
    await _syncPlayback();
  }

  Future<void> endSession() async {
    _isStarted = false;
    _isEligibleStudent = false;
    _gameModeCount = 0;
    _isMusicEnabled = true;
    _musicEnabled.value = true;
    await _syncPlayback();
  }

  Future<void> onAppPaused() async {
    _isForeground = false;
    await _syncPlayback();
  }

  Future<void> onAppResumed() async {
    _isForeground = true;
    await _syncPlayback();
  }

  Future<void> _syncPlayback() {
    final player = _player;
    if (player == null) return Future<void>.value();

    _playbackUpdate = _playbackUpdate.then((_) async {
      if (!identical(_player, player)) return;
      final shouldPlay = _isStarted &&
          _isEligibleStudent &&
          _isReady &&
          _isMusicEnabled &&
          _isForeground &&
          _gameModeCount == 0;
      try {
        if (shouldPlay) {
          if (!_isPlaybackRequested) {
            _isPlaybackRequested = true;
            unawaited(_play(player));
          }
        } else if (_isPlaybackRequested) {
          _isPlaybackRequested = false;
          await player.pause();
        }
      } catch (error, stackTrace) {
        _logAudioError(
            'update application background music', error, stackTrace);
      }
    });
    return _playbackUpdate;
  }

  Future<void> _play(AudioPlayer player) async {
    try {
      await player.play();
    } catch (error, stackTrace) {
      if (identical(_player, player)) _isPlaybackRequested = false;
      _logAudioError('play application background music', error, stackTrace);
    }
  }

  Future<void> dispose() async {
    final player = _player;
    _player = null;
    _isStarted = false;
    _isEligibleStudent = false;
    _gameModeCount = 0;
    _isForeground = false;
    _isPlaybackRequested = false;
    _isReady = false;
    _initialization = null;
    if (player == null) return;

    try {
      await _playbackUpdate;
      await player.dispose();
    } catch (error, stackTrace) {
      _logAudioError('dispose application background music', error, stackTrace);
    }
  }

  void _logAudioError(String action, Object error, StackTrace stackTrace) {
    if (error is MissingPluginException ||
        error.toString().contains('MissingPluginException')) {
      debugPrint('Audio unavailable; could not $action.');
      return;
    }
    debugPrint('Unable to $action: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}
