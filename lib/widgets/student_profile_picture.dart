import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/user_account.dart';
import '../services/auth_service.dart';

class StudentProfilePicture extends StatefulWidget {
  const StudentProfilePicture({
    required this.uid,
    required this.profilePhotoUrl,
    required this.character,
    this.size = 50,
    super.key,
  });

  final String uid;
  final String profilePhotoUrl;
  final String character;
  final double size;

  @override
  State<StudentProfilePicture> createState() => _StudentProfilePictureState();
}

class _StudentProfilePictureState extends State<StudentProfilePicture> {
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _photoStream;

  @override
  void initState() {
    super.initState();
    _updatePhotoStream();
  }

  @override
  void didUpdateWidget(covariant StudentProfilePicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid ||
        oldWidget.profilePhotoUrl != widget.profilePhotoUrl) {
      _updatePhotoStream();
    }
  }

  void _updatePhotoStream() {
    _photoStream =
        widget.profilePhotoUrl == AuthService.firestoreProfilePhotoUrl &&
                widget.uid.isNotEmpty
            ? FirebaseFirestore.instance
                .collection('users')
                .doc(widget.uid)
                .collection('profileData')
                .doc('photo')
                .snapshots()
            : null;
  }

  Uint8List? _decodePhoto(String? photoData) {
    if (photoData == null || !photoData.startsWith('data:image/')) {
      return null;
    }
    final separator = photoData.indexOf(',');
    if (separator < 0) return null;
    try {
      return base64Decode(photoData.substring(separator + 1));
    } on FormatException catch (error) {
      debugPrint('Unable to decode saved student profile picture: $error');
      return null;
    }
  }

  ImageProvider<Object>? _savedImageProvider() {
    final photoUrl = widget.profilePhotoUrl;
    if (UserAccount.isCharacterProfileImageAsset(photoUrl)) {
      return AssetImage(photoUrl);
    }
    if (photoUrl.startsWith('data:image/')) {
      final bytes = _decodePhoto(photoUrl);
      return bytes == null ? null : MemoryImage(bytes);
    }
    final uri = Uri.tryParse(photoUrl);
    if (uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty) {
      return NetworkImage(photoUrl);
    }
    return null;
  }

  Widget _buildAvatar(ImageProvider<Object>? imageProvider) {
    final fallbackAsset =
        UserAccount.profileImageAssetPathForCharacter(widget.character);
    return CircleAvatar(
      radius: widget.size / 2,
      backgroundColor: const Color(0xFFD09F5C),
      child: ClipOval(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: imageProvider == null
              ? Image.asset(fallbackAsset, fit: BoxFit.cover)
              : Image(
                  image: imageProvider,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    debugPrint(
                        'Unable to render student profile picture: $error');
                    return Image.asset(fallbackAsset, fit: BoxFit.cover);
                  },
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localProvider = _savedImageProvider();
    if (localProvider != null || _photoStream == null) {
      return _buildAvatar(localProvider);
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _photoStream,
      builder: (context, snapshot) {
        final photoData = snapshot.data?.data()?['data'];
        final bytes = _decodePhoto(photoData is String ? photoData : null);
        return _buildAvatar(bytes == null ? null : MemoryImage(bytes));
      },
    );
  }
}
