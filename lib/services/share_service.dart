import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:mime/mime.dart';
import 'package:flutter/foundation.dart';

/// Represents a file shared via a capability URL (an unguessable token-based link).
/// CN concept: TTL (Time-To-Live) — each share has a fixed lifetime before expiry,
/// analogous to DNS record TTL and IP packet TTL fields.
class SharedFile {
  final String token;
  final String filePath;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final DateTime createdAt;
  final DateTime expiresAt; // TTL expires after 24h
  int downloadCount;

  SharedFile({
    required this.token,
    required this.filePath,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.createdAt,
    required this.expiresAt,
    this.downloadCount = 0,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  Duration get remainingTtl => expiresAt.difference(DateTime.now());

  Map<String, dynamic> toJson() => {
        'token': token,
        'fileName': fileName,
        'fileSize': fileSize,
        'fileSizeFormatted': fmtBytes(fileSize),
        'mimeType': mimeType,
        'createdAt': createdAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'ttlSeconds': remainingTtl.inSeconds.clamp(0, 86400),
        'downloadCount': downloadCount,
        'isExpired': isExpired,
      };

  static String fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(1)} GB';
  }
}

/// CN Concepts demonstrated by this service:
/// 1. Capability URLs — security through an unguessable random token (no PIN needed to download)
/// 2. TTL (Time-To-Live) — 24h expiry mimics DNS TTL and IP packet TTL
/// 3. Content-Addressable Lookup — files identified by token, not path
/// 4. Concurrent Access — multiple TCP connections can stream the same file simultaneously
/// 5. Resource Cleanup — expired entries purged automatically (like ARP cache expiry)
class ShareService {
  static final ShareService _instance = ShareService._();
  factory ShareService() => _instance;

  ShareService._() {
    // Background cleanup timer — removes expired shares every hour
    _cleanupTimer = Timer.periodic(const Duration(hours: 1), (_) => cleanupExpired());
  }

  final Map<String, SharedFile> _shares = {};
  final Random _rng = Random.secure();
  Timer? _cleanupTimer;

  /// Generates a 20-char cryptographically random token — the "capability".
  String _generateToken() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(20, (_) => chars[_rng.nextInt(chars.length)]).join();
  }

  Future<SharedFile> createShare({
    required String filePath,
    required String fileName,
    required int fileSize,
    Duration ttl = const Duration(hours: 24),
  }) async {
    final token = _generateToken();
    final mime = lookupMimeType(fileName) ?? 'application/octet-stream';
    final now = DateTime.now();
    final share = SharedFile(
      token: token,
      filePath: filePath,
      fileName: fileName,
      mimeType: mime,
      fileSize: fileSize,
      createdAt: now,
      expiresAt: now.add(ttl),
    );
    _shares[token] = share;
    debugPrint('Share created: $token → $fileName (TTL: ${ttl.inHours}h)');
    return share;
  }

  SharedFile? getShare(String token) {
    final share = _shares[token];
    if (share == null) return null;
    if (share.isExpired) {
      _deleteShare(token, share);
      return null;
    }
    return share;
  }

  void incrementDownload(String token) {
    _shares[token]?.downloadCount++;
  }

  List<Map<String, dynamic>> listAll() {
    cleanupExpired();
    return _shares.values.map((s) => s.toJson()).toList()
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
  }

  bool deleteShare(String token) {
    final share = _shares[token];
    if (share == null) return false;
    _deleteShare(token, share);
    return true;
  }

  void cleanupExpired() {
    final expired = _shares.entries.where((e) => e.value.isExpired).toList();
    for (final e in expired) {
      _deleteShare(e.key, e.value);
    }
    if (expired.isNotEmpty) debugPrint('Share cleanup: removed ${expired.length} expired shares');
  }

  void _deleteShare(String token, SharedFile share) {
    try {
      final f = File(share.filePath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    _shares.remove(token);
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _shares.clear();
  }
}
