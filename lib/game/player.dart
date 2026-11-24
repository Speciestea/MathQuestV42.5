import 'dart:ui' as ui;

import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'math_world_game.dart';

enum _FacingDirection { down, up, left, right }

class Player extends SpriteAnimationComponent
    with KeyboardHandler, CollisionCallbacks, HasGameReference<MathWorldGame> {
  static const String boySpriteAssetPath = 'assets/images/player/character.png';
  static const String girlSpriteAssetPath =
      'assets/images/player/character2.png';
  static const String trexSpriteAssetPath =
      'assets/images/player/character3.png';
  static const String prideFemmeSpriteAssetPath =
      'assets/images/player/character4.png';
  static const String prideMascSpriteAssetPath =
      'assets/images/player/character5.png';
  static const double feetCollisionRadius =
      MathWorldGame.playerFeetCollisionRadius;

  final String characterId;
  static const double walkSpeed = 80;
  static const double _facingDirectionChangeRatio = 1.2;

  final Set<int> collectedNumbers = {};

  bool isMoving = false;

  Vector2 lastMove = Vector2.zero();

  Vector2 moveDirection = Vector2.zero();
  final Vector2 _candidatePosition = Vector2.zero();
  List<int> _frameRowTops = const [];
  _FacingDirection _facingDirection = _FacingDirection.down;

  SpriteAnimation? walkAnimation;
  SpriteAnimation? idleAnimation;
  SpriteAnimation? downAnimation;
  SpriteAnimation? upAnimation;
  SpriteAnimation? leftAnimation;
  SpriteAnimation? rightAnimation;
  SpriteAnimation? downIdleAnimation;
  SpriteAnimation? upIdleAnimation;
  SpriteAnimation? leftIdleAnimation;
  SpriteAnimation? rightIdleAnimation;

  Player({String characterId = 'boy'})
      : characterId = switch (characterId) {
          'girl' => 'girl',
          'character3' => 'character3',
          'character4' => 'character4',
          'character5' => 'character5',
          _ => 'boy',
        },
        super(
          anchor: Anchor.center,
        );

  String get spriteAssetPath => switch (characterId) {
        'girl' => girlSpriteAssetPath,
        'character3' => trexSpriteAssetPath,
        'character4' => prideFemmeSpriteAssetPath,
        'character5' => prideMascSpriteAssetPath,
        _ => boySpriteAssetPath,
      };

  @override
  Future<void> onLoad() async {
    ui.Image? image;
    try {
      image = await _decodeSprite(spriteAssetPath);
    } catch (error, stackTrace) {
      debugPrint('Unable to load $characterId player sprite: $error');
      debugPrintStack(stackTrace: stackTrace);

      if (characterId != 'boy') {
        try {
          image = await _decodeSprite(boySpriteAssetPath);
          debugPrint('Loaded the Boy sprite as a player fallback.');
        } catch (fallbackError, fallbackStackTrace) {
          debugPrint('Unable to load the Boy player fallback: $fallbackError');
          debugPrintStack(stackTrace: fallbackStackTrace);
        }
      }
    }

    if (image != null) {
      _configureAnimations(image);
    } else {
      size = Vector2(32, 48);
      add(
        RectangleComponent(
          size: Vector2(32, 48),
          paint: Paint()..color = const Color(0xFF0000FF),
          anchor: Anchor.center,
        ),
      );
    }

    add(
      CircleHitbox(
        radius: feetCollisionRadius,
        position: Vector2(0, 21),
      ),
    );
    _updateDepthPriority();
  }

  Future<ui.Image> _decodeSprite(String assetPath) async {
    final spriteBytes = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(
      spriteBytes.buffer.asUint8List(),
    );
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  void _configureAnimations(ui.Image image) {
    if (image.width >= 6 && image.height >= 4) {
      try {
        _frameRowTops = _getFrameRowTops(image, characterId);
        downAnimation = _createRowAnimation(image, 0);
        upAnimation = _createRowAnimation(image, 1);
        leftAnimation = _createRowAnimation(image, 2);
        rightAnimation = _createRowAnimation(image, 3);

        downIdleAnimation = _createIdleAnimation(image, 0);
        upIdleAnimation = _createIdleAnimation(image, 1);
        leftIdleAnimation = _createIdleAnimation(image, 2);
        rightIdleAnimation = _createIdleAnimation(image, 3);

        idleAnimation = downIdleAnimation;
        walkAnimation = downAnimation;
        size = Vector2(32, 48);
      } catch (error, stackTrace) {
        debugPrint('Unable to create player sprite animations: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }

    if (idleAnimation == null || walkAnimation == null) {
      size = Vector2(32, 48);
      final fullSprite = Sprite(image);
      idleAnimation = SpriteAnimation.spriteList(
        [fullSprite],
        stepTime: 1.0,
        loop: true,
      );
      downIdleAnimation = idleAnimation;
      upIdleAnimation = idleAnimation;
      leftIdleAnimation = idleAnimation;
      rightIdleAnimation = idleAnimation;
      walkAnimation = idleAnimation;
      downAnimation = idleAnimation;
      upAnimation = idleAnimation;
      leftAnimation = idleAnimation;
      rightAnimation = idleAnimation;
    }

    animation = idleAnimation;
    debugPrint('Player animation loaded successfully from $spriteAssetPath');
  }

  SpriteAnimation _createRowAnimation(ui.Image image, int row) {
    final frames = List.generate(
      6,
      (column) => _spriteAtFrame(image, column, row),
    );

    return SpriteAnimation.spriteList(
      frames,
      stepTime: 0.12,
      loop: true,
    );
  }

  SpriteAnimation _createIdleAnimation(ui.Image image, int row) {
    return SpriteAnimation.spriteList(
      [_spriteAtFrame(image, 0, row)],
      stepTime: 1.0,
      loop: true,
    );
  }

  List<int> _getFrameRowTops(ui.Image image, String characterId) {
    // The artwork crosses nominal row boundaries; these starts use the clear gaps.
    if (image.width == 768 && image.height == 768) {
      if (characterId == 'character3' ||
          characterId == 'character4' ||
          characterId == 'character5') {
        return const [0, 192, 384, 576];
      }
      return const [5, 197, 384, 576];
    }
    if (image.width == 1254 && image.height == 1254) {
      return const [12, 336, 627, 941];
    }

    return List.generate(4, (row) => row * image.height ~/ 4);
  }

  Sprite _spriteAtFrame(ui.Image image, int column, int row) {
    final left = column * image.width ~/ 6;
    final right = (column + 1) * image.width ~/ 6;
    final top = _frameRowTops[row];
    final bottom = top + image.height ~/ 4;

    return Sprite(
      image,
      srcPosition: Vector2(left.toDouble(), top.toDouble()),
      srcSize: Vector2(
        (right - left).toDouble(),
        (bottom - top).toDouble(),
      ),
    );
  }

  @override
  void render(ui.Canvas canvas) {
    final sprite = animationTicker?.getSprite();
    var verticalOffset = 0.0;
    if (sprite != null) {
      final row = _frameRowTops.indexWhere(
        (top) => top.toDouble() == sprite.srcPosition.y,
      );
      if (row >= 0) {
        verticalOffset = (_frameRowTops[row] - row * sprite.image.height / 4) *
            size.y /
            sprite.srcSize.y;
      }
    }

    canvas.save();
    try {
      canvas.translate(0, verticalOffset);
      super.render(canvas);
    } finally {
      canvas.restore();
    }
  }

  @override
  void update(
    double dt,
  ) {
    super.update(dt);

    if (game.isMovementPaused) {
      moveDirection.setZero();
      lastMove.setZero();

      isMoving = false;
      idleAnimation = _idleAnimationForFacing;
      _setAnimation(idleAnimation);

      _updateDepthPriority();
      return;
    }

    // ============================================================
    // MOVEMENT
    // ============================================================

    var directionX = moveDirection.x;
    var directionY = moveDirection.y;
    final horizontalInput = directionX.abs();
    final verticalInput = directionY.abs();
    if (horizontalInput > 0 && verticalInput > 0) {
      final isCurrentlyFacingHorizontally =
          _facingDirection == _FacingDirection.left ||
              _facingDirection == _FacingDirection.right;
      if (isCurrentlyFacingHorizontally) {
        if (verticalInput > horizontalInput * _facingDirectionChangeRatio) {
          directionX = 0;
        } else {
          directionY = 0;
        }
      } else if (horizontalInput >
          verticalInput * _facingDirectionChangeRatio) {
        directionY = 0;
      } else {
        directionX = 0;
      }
    }

    final directionLength = directionX.abs() + directionY.abs();
    if (directionLength > 0) {
      final movementX = directionX / directionLength * walkSpeed * dt;
      final movementY = directionY / directionLength * walkSpeed * dt;

      // ==========================================================
      // FEET-ONLY COLLISION
      // ==========================================================

      const collisionRadius = feetCollisionRadius;

      var moved = false;
      var actualMovementX = 0.0;
      var actualMovementY = 0.0;

      // ----------------------------------------------------------
      // HORIZONTAL MOVEMENT
      // ----------------------------------------------------------

      if (movementX != 0) {
        _candidatePosition
          ..x = position.x + movementX
          ..y = position.y + 21;
      }

      if (movementX != 0) {
        if (game.canPlayerMoveTo(_candidatePosition, collisionRadius)) {
          position.x += movementX;
          actualMovementX = movementX;
          moved = true;
        } else if (game.canPlayerMoveTo(
          _candidatePosition,
          collisionRadius,
          checkNpcCollisions: false,
        )) {
          game.checkNpcCollisionsAt(_candidatePosition, collisionRadius);
          if (game.isMovementPaused) {
            idleAnimation = _idleAnimationForFacing;
            _setAnimation(idleAnimation);
            _updateDepthPriority();
            return;
          }
        }
      }

      // ----------------------------------------------------------
      // VERTICAL MOVEMENT
      // ----------------------------------------------------------

      if (movementY != 0) {
        _candidatePosition
          ..x = position.x
          ..y = position.y + movementY + 21;
      }

      if (movementY != 0) {
        if (game.canPlayerMoveTo(_candidatePosition, collisionRadius)) {
          position.y += movementY;
          actualMovementY = movementY;
          moved = true;
        } else if (game.canPlayerMoveTo(
          _candidatePosition,
          collisionRadius,
          checkNpcCollisions: false,
        )) {
          game.checkNpcCollisionsAt(_candidatePosition, collisionRadius);
        }
      }

      lastMove.setValues(
        actualMovementX,
        actualMovementY,
      );

      isMoving = moved;

      if (moved) {
        _updateFacingDirection(directionX, directionY);
      }
    } else {
      lastMove.setZero();

      isMoving = false;
    }

    idleAnimation = _idleAnimationForFacing;
    if (!isMoving) {
      _setAnimation(idleAnimation);
    } else {
      _setAnimation(_walkAnimationForFacing);
    }

    // ============================================================
    // MAP BOUNDARIES
    // ============================================================

    if (position.x < 0) {
      position.x = 0;
    }

    if (position.y < 0) {
      position.y = 0;
    }

    if (position.x > game.mapWidth) {
      position.x = game.mapWidth;
    }

    if (position.y > game.mapHeight) {
      position.y = game.mapHeight;
    }
    _updateDepthPriority();
  }

  SpriteAnimation? get _walkAnimationForFacing => switch (_facingDirection) {
        _FacingDirection.down => downAnimation ?? walkAnimation,
        _FacingDirection.up => upAnimation ?? walkAnimation,
        _FacingDirection.left => leftAnimation ?? walkAnimation,
        _FacingDirection.right => rightAnimation ?? walkAnimation,
      };

  SpriteAnimation? get _idleAnimationForFacing => switch (_facingDirection) {
        _FacingDirection.down => downIdleAnimation ?? idleAnimation,
        _FacingDirection.up => upIdleAnimation ?? idleAnimation,
        _FacingDirection.left => leftIdleAnimation ?? idleAnimation,
        _FacingDirection.right => rightIdleAnimation ?? idleAnimation,
      };

  void _updateFacingDirection(double movementX, double movementY) {
    final horizontalMovement = movementX.abs();
    final verticalMovement = movementY.abs();
    final isCurrentlyFacingHorizontally =
        _facingDirection == _FacingDirection.left ||
            _facingDirection == _FacingDirection.right;

    if (isCurrentlyFacingHorizontally) {
      if (verticalMovement > horizontalMovement * _facingDirectionChangeRatio) {
        _facingDirection =
            movementY > 0 ? _FacingDirection.down : _FacingDirection.up;
      } else if (horizontalMovement >
          verticalMovement * _facingDirectionChangeRatio) {
        _facingDirection =
            movementX > 0 ? _FacingDirection.right : _FacingDirection.left;
      }
    } else if (horizontalMovement >
        verticalMovement * _facingDirectionChangeRatio) {
      _facingDirection =
          movementX > 0 ? _FacingDirection.right : _FacingDirection.left;
    } else if (verticalMovement > 0) {
      _facingDirection =
          movementY > 0 ? _FacingDirection.down : _FacingDirection.up;
    }
  }

  void _setAnimation(SpriteAnimation? nextAnimation) {
    if (nextAnimation != null && animation != nextAnimation) {
      animation = nextAnimation;
    }
  }

  void _updateDepthPriority() {
    priority = (position.y + size.y / 2).round();
  }

  @override
  bool onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    if (game.isMovementPaused) {
      moveDirection.setZero();

      return true;
    }

    moveDirection.setZero();

    if (keysPressed.contains(
          LogicalKeyboardKey.arrowRight,
        ) ||
        keysPressed.contains(
          LogicalKeyboardKey.keyD,
        )) {
      moveDirection.x = 1;
    }

    if (keysPressed.contains(
          LogicalKeyboardKey.arrowLeft,
        ) ||
        keysPressed.contains(
          LogicalKeyboardKey.keyA,
        )) {
      moveDirection.x = -1;
    }

    if (keysPressed.contains(
          LogicalKeyboardKey.arrowUp,
        ) ||
        keysPressed.contains(
          LogicalKeyboardKey.keyW,
        ) ||
        keysPressed.contains(
          LogicalKeyboardKey.keyE,
        )) {
      moveDirection.y = -1;
    }

    if (keysPressed.contains(
          LogicalKeyboardKey.arrowDown,
        ) ||
        keysPressed.contains(
          LogicalKeyboardKey.keyS,
        ) ||
        keysPressed.contains(
          LogicalKeyboardKey.keyF,
        )) {
      moveDirection.y = 1;
    }

    return true;
  }

  void addCollectedNumber(
    int number,
  ) {
    collectedNumbers.add(
      number,
    );
  }

  bool hasCollected(
    int number,
  ) {
    return collectedNumbers.contains(
      number,
    );
  }

  Set<int> getCollectedNumbers() {
    return Set.from(
      collectedNumbers,
    );
  }
}

class Character extends Player {
  Character({super.characterId = 'boy'});
}
