import 'dart:io';
import 'package:mime/mime.dart';
import 'dart:math';
import 'dart:convert';
import 'web_ui.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'scanner_service.dart';
import 'chat_service.dart';
import 'speedtest_service.dart';
import 'wol_service.dart';
import 'stats_service.dart';
import 'share_service.dart';

class ServerService {
  HttpServer? _server;
  final String sharedDirectoryPath;
  final String pin;
  final Function(String) onLog;
  int port = 8080;
  final ChatService _chatService = ChatService();
  final StatsService _stats = StatsService();
  final ShareService _shareService = ShareService();
  bool _scanInProgress = false;

  ServerService(this.sharedDirectoryPath, this.pin, {required this.onLog});

  Future<void> startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      debugPrint("Server running on port ${_server!.port}");
      
      _server!.listen((HttpRequest request) {
        _handleRequest(request);
      });
    } catch (e) {
      debugPrint("Error starting server: $e");
      rethrow;
    }
  }

  void stopServer() {
    _chatService.dispose();
    _shareService.dispose();
    _stats.reset();
    _server?.close(force: true);
    _server = null;
    debugPrint("Server stopped");
  }



  bool get isRunning => _server != null;

  bool _isAuthenticated(HttpRequest request) {
    if (request.headers.value('X-Vault-Pin') == pin) return true;
    return request.cookies.any((cookie) => cookie.name == 'vault_pin' && cookie.value == pin);
  }

  void _log(String message, HttpRequest request) {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'Unknown';
    onLog("[$ip] $message");
  }

    void _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;

    // Track every request in stats
    _stats.recordRequest(request);

    // CORS headers (for dev/testing from browser)
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type, X-Vault-Pin');
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.ok;
      await response.close();
      return;
    }

    try {
      if (path == '/') {
        response.headers.contentType = ContentType.html;
        response.write(webUiHtml);
        await response.close();
        return;
      }


      if (path == '/api/login' && request.method == 'POST') {
        final submittedPin = request.uri.queryParameters['pin'];
        if (submittedPin == pin) {
          _log("Successfully unlocked vault", request);
          response.headers.add('Set-Cookie', 'vault_pin=$pin; Path=/; HttpOnly');
          response.statusCode = HttpStatus.ok;
          response.write('{"success": true}');
        } else {
          _log("Failed login attempt", request);
          response.statusCode = HttpStatus.unauthorized;
          response.write('{"error": "Invalid PIN"}');
        }
        await response.close();
        return;
      }

      if (!_isAuthenticated(request)) {
        _log("Blocked unauthenticated access", request);
        response.statusCode = HttpStatus.unauthorized;
        response.write('{"error": "Unauthorized"}');
        await response.close();
        return;
      }

      if (path == '/api/upload' && request.method == 'POST') {
        _log("Started uploading a file...", request);
        await _handleUpload(request, response);
      } else if (path == '/api/download_all') {
        _log("Downloading all files as ZIP", request);
        await _handleDownloadAll(request, response);
      } else if (path == '/api/download_selected_zip' && request.method == 'POST') {
        _log("Downloading selected files as ZIP", request);
        await _handleDownloadSelectedZip(request, response);
      } else if (path == '/api/files') {
        _log("Viewing file list", request);
        await _serveApiFilesList(request, response);
      } else if (path == '/api/download') {
        final filePathParam = request.uri.queryParameters['path'] ?? 'unknown';
        _log("Downloading: $filePathParam", request);
        await _serveFile(request, response, inline: false);
      } else if (path == '/api/view') {
        final filePathParam = request.uri.queryParameters['path'] ?? 'unknown';
        _log("Streaming/Viewing: $filePathParam", request);
        await _serveFile(request, response, inline: true);
      } else if (path == '/api/clipboard') {
        if (request.method == 'GET') {
          _log("Reading clipboard", request);
          final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
          response.headers.contentType = ContentType.json;
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode({"text": clipboardData?.text ?? ""}));
          await response.close();
        } else if (request.method == 'POST') {
          _log("Writing to clipboard", request);
          String body = await utf8.decoder.bind(request).join();
          Map<String, dynamic> data = jsonDecode(body);
          String newText = data['text'] ?? '';
          await Clipboard.setData(ClipboardData(text: newText));
          response.headers.contentType = ContentType.json;
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode({"success": true}));
          await response.close();
        } else {
          _sendNotFound(response);
        }

      // ── LAN Network Scanner ──────────────────────────────────────────────
      } else if (path == '/api/scan' && request.method == 'GET') {
        if (_scanInProgress) {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({'error': 'Scan already in progress'}));
          await response.close();
          return;
        }
        String localIp = '192.168.1.1';
        try {
          final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
          for (final iface in interfaces) {
            for (final addr in iface.addresses) {
              if (addr.address.startsWith('192.168.') || addr.address.startsWith('10.')) {
                localIp = addr.address;
                break;
              }
            }
          }
        } catch (_) {}
        _log("Starting subnet scan from $localIp", request);
        _scanInProgress = true;
        try {
          final results = await ScannerService.scanSubnet(localIp);
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(results.map((r) => r.toJson()).toList()));
        } finally {
          _scanInProgress = false;
        }
        await response.close();

      // ── WebSocket Chat ───────────────────────────────────────────────────
      } else if (path == '/ws/chat') {
        _log("Chat client connected (WS)", request);
        await _chatService.handleUpgrade(request);

      // ── Speed Test ───────────────────────────────────────────────────────
      } else if (path == '/api/speedtest/ping') {
        SpeedTestService.handlePing(response);
      } else if (path == '/api/speedtest/download' && request.method == 'GET') {
        final sizeMb = int.tryParse(request.uri.queryParameters['size'] ?? '10') ?? 10;
        _log("Speed test download: ${sizeMb.clamp(1,100)}MB", request);
        await SpeedTestService.handleDownload(request, response, sizeMb.clamp(1, 100));
        _stats.recordBytesOut(sizeMb.clamp(1, 100) * 1024 * 1024);
      } else if (path == '/api/speedtest/upload' && request.method == 'POST') {
        _log("Speed test upload started", request);
        final result = await SpeedTestService.handleUpload(request);
        _stats.recordBytesIn(result['receivedBytes'] as int);
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(result));
        await response.close();

      // ── Wake-on-LAN ──────────────────────────────────────────────────────
      } else if (path == '/api/wol' && request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final mac = data['mac'] as String? ?? '';
        _log("WoL: sending magic packet to $mac", request);
        final result = await WolService.sendMagicPacket(mac);
        response.headers.contentType = ContentType.json;
        response.statusCode = (result['success'] as bool) ? HttpStatus.ok : HttpStatus.badRequest;
        response.write(jsonEncode(result));
        await response.close();


      // ── Network Stats Dashboard ──────────────────────────────────────────
      } else if (path == '/api/stats' && request.method == 'GET') {
        final statsMap = _stats.getStats();
        statsMap['chatClients'] = _chatService.clientCount;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(statsMap));
        await response.close();

      // ── File Sharing (Capability URLs + TTL) ────────────────────────────
      // POST /api/share/upload → upload file, get shareable link (auth required)
      } else if (path == '/api/share/upload' && request.method == 'POST') {
        _log("Share upload started", request);
        await _handleShareUpload(request, response);

      // GET /api/share/list → list all active shares (auth required)
      } else if (path == '/api/share/list' && request.method == 'GET') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(_shareService.listAll()));
        await response.close();

      // DELETE /api/share/<token> → revoke a share (auth required)
      } else if (path.startsWith('/api/share/delete/') && request.method == 'POST') {
        final token = path.substring('/api/share/delete/'.length);
        final deleted = _shareService.deleteShare(token);
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'success': deleted}));
        await response.close();

      // GET /share/<token> → public download page (NO auth required — capability URL)
      } else if (path.startsWith('/share/') && request.method == 'GET') {
        final token = path.substring('/share/'.length).split('/').first;
        final isDownload = path.endsWith('/download');
        final share = _shareService.getShare(token);
        if (share == null) {
          response.statusCode = HttpStatus.notFound;
          response.headers.contentType = ContentType.html;
          response.write(_buildExpiredPage());
          await response.close();
        } else if (isDownload) {
          // Serve the actual file — multiple concurrent connections supported
          _shareService.incrementDownload(token);
          _log("Share download: ${share.fileName} (token: $token, count: ${share.downloadCount})", request);
          final file = File(share.filePath);
          if (!await file.exists()) {
            response.statusCode = HttpStatus.notFound;
            response.write('File not found');
            await response.close();
            return;
          }
          response.headers.contentType = ContentType.parse(share.mimeType);
          response.headers.add('Content-Disposition', 'attachment; filename="${share.fileName}"');
          response.headers.contentLength = share.fileSize;
          response.headers.add('Accept-Ranges', 'bytes');
          try {
            await file.openRead().pipe(response);
          } catch (_) { await response.close(); }
        } else {
          // Serve the share info page (HTML)
          response.headers.contentType = ContentType.html;
          response.write(_buildSharePage(share, request));
          await response.close();
        }

      } else {
        _sendNotFound(response);
      }

    } catch (e) {
      _log("Error: $e", request);
      response.statusCode = HttpStatus.internalServerError;
      response.write("Internal Server Error: $e");
      await response.close();
    }
  }

Future<void> _handleUpload(HttpRequest request, HttpResponse response) async {
    final contentType = request.headers.contentType;
    if (contentType == null || contentType.primaryType != 'multipart' || contentType.subType != 'form-data') {
      _sendNotFound(response);
      return;
    }

    final boundary = contentType.parameters['boundary'];
    if (boundary == null) {
      _sendNotFound(response);
      return;
    }

    try {
      final transformer = MimeMultipartTransformer(boundary);
      final parts = request.cast<List<int>>().transform(transformer);

      await for (final part in parts) {
        final contentDisposition = part.headers['content-disposition'];
        if (contentDisposition != null) {
          final match = RegExp(r'filename="([^"]+)"').firstMatch(contentDisposition);
          if (match != null) {
            final filename = match.group(1);
            if (filename != null && filename.isNotEmpty) {
               final savePath = '$sharedDirectoryPath${Platform.pathSeparator}$filename';
               final file = File(savePath);
               final sink = file.openWrite();
               await part.cast<List<int>>().pipe(sink);
               await sink.close();
            }
          }
        }
      }

      // Redirect back to the files list
      response.statusCode = HttpStatus.ok;
      await response.close();
    } catch (e) {
      debugPrint("Error handling upload: $e");
      response.statusCode = HttpStatus.internalServerError;
      response.write("Upload failed");
      await response.close();
    }
  }

  Future<void> _handleDownloadAll(HttpRequest request, HttpResponse response) async {
    try {
      final dir = Directory(sharedDirectoryPath);
      if (!dir.existsSync()) {
        _sendNotFound(response);
        return;
      }

      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final zipFilePath = '${tempDir.path}${Platform.pathSeparator}vault_backup_$timestamp.zip';
      
      var encoder = ZipFileEncoder();
      encoder.create(zipFilePath);
      
      final entities = dir.listSync();
      for (var entity in entities) {
        if (entity is File) {
          encoder.addFile(entity);
        } else if (entity is Directory) {
          encoder.addDirectory(entity);
        }
      }
      encoder.close();

      final zipFile = File(zipFilePath);
      if (!await zipFile.exists()) {
        _sendNotFound(response);
        return;
      }

      final zipName = "WiFi_Vault_Backup.zip";
      
      response.headers.contentType = ContentType('application', 'zip');
      response.headers.add('content-disposition', 'attachment; filename="$zipName"');
      
      await zipFile.openRead().pipe(response);
      
      if (await zipFile.exists()) {
        await zipFile.delete();
      }

    } catch (e) {
      debugPrint("Error creating zip: $e");
      response.statusCode = HttpStatus.internalServerError;
      response.write("Failed to create ZIP");
      await response.close();
    }
  }

  Future<void> _handleDownloadSelectedZip(HttpRequest request, HttpResponse response) async {
    try {
      String body = await utf8.decoder.bind(request).join();
      Map<String, dynamic> data = jsonDecode(body);
      List<dynamic> filenames = data['files'] ?? [];

      if (filenames.isEmpty) {
        response.statusCode = HttpStatus.badRequest;
        response.write("No files selected");
        await response.close();
        return;
      }

      final dir = Directory(sharedDirectoryPath);
      if (!dir.existsSync()) {
        _sendNotFound(response);
        return;
      }

      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final zipFilePath = '${tempDir.path}${Platform.pathSeparator}vault_selected_$timestamp.zip';
      
      var encoder = ZipFileEncoder();
      encoder.create(zipFilePath);
      
      for (String name in filenames) {
        if (name.contains('..') || name.startsWith('/') || name.startsWith('\\')) continue;
        final filePath = '${dir.path}${Platform.pathSeparator}$name';
        final file = File(filePath);
        if (file.existsSync()) {
          encoder.addFile(file);
        }
      }
      encoder.close();

      final zipFile = File(zipFilePath);
      if (!await zipFile.exists()) {
        _sendNotFound(response);
        return;
      }

      final zipName = "WiFi_Vault_Selected.zip";
      
      response.headers.contentType = ContentType('application', 'zip');
      response.headers.add('content-disposition', 'attachment; filename="$zipName"');
      
      await zipFile.openRead().pipe(response);
      
      if (await zipFile.exists()) {
        await zipFile.delete();
      }

    } catch (e) {
      debugPrint("Error creating selected zip: $e");
      response.statusCode = HttpStatus.internalServerError;
      response.write("Failed to create ZIP");
      await response.close();
    }
  }

      Future<void> _serveApiFilesList(HttpRequest request, HttpResponse response) async {
    String subPath = request.uri.queryParameters['path'] ?? '';
    
    // Security check: Prevent directory traversal
    if (subPath.contains('..') || subPath.startsWith('/') || subPath.startsWith('\\')) {
      response.statusCode = HttpStatus.badRequest;
      response.write('[]');
      await response.close();
      return;
    }

    final targetDirPath = subPath.isEmpty 
        ? sharedDirectoryPath 
        : '$sharedDirectoryPath${Platform.pathSeparator}$subPath';
    
    final dir = Directory(targetDirPath);
    
    if (!dir.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      response.write('[]');
      await response.close();
      return;
    }

    final entities = dir.listSync();
    List<Map<String, dynamic>> filesData = [];

    for (var entity in entities) {
      final name = entity.path.split(Platform.pathSeparator).last;

      if (entity is Directory) {
        filesData.add({
          'name': name,
          'ext': '',
          'size': '-',
          'isDir': true
        });
      } else if (entity is File) {
        final sizeBytes = entity.lengthSync();
        final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
        
        String formattedSize;
        if (sizeBytes <= 0) {
          formattedSize = "0 B";
        } else {
          const suffixes = ["B", "KB", "MB", "GB", "TB"];
          var i = (log(sizeBytes) / log(1024)).floor();
          formattedSize = '${(sizeBytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
        }

        filesData.add({
          'name': name,
          'ext': ext,
          'size': formattedSize,
          'isDir': false
        });
      }
    }

    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(filesData));
    await response.close();
  }

  void _sendNotFound(HttpResponse response) {
    response.statusCode = HttpStatus.notFound;
    response.write("Not Found");
    response.close();
  }

  Future<void> _serveFile(HttpRequest request, HttpResponse response, {bool inline = false}) async {
    final requestedPath = request.uri.queryParameters['path'];
    if (requestedPath == null || requestedPath.contains('..') || requestedPath.startsWith('/') || requestedPath.startsWith('\\')) {
       _sendNotFound(response);
       return;
    }

    final file = File('$sharedDirectoryPath${Platform.pathSeparator}$requestedPath');
    if (!await file.exists()) {
      _sendNotFound(response);
      return;
    }

    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    response.headers.contentType = ContentType.parse(mimeType);
    
    if (inline) {
       response.headers.add('content-disposition', 'inline; filename="$requestedPath"');
    } else {
       response.headers.add('content-disposition', 'attachment; filename="$requestedPath"');
    }

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final fileLength = await file.length();

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      int start = int.tryParse(parts[0]) ?? 0;
      int end = parts.length > 1 && parts[1].isNotEmpty ? int.parse(parts[1]) : fileLength - 1;

      if (start >= fileLength || end >= fileLength || start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.add(HttpHeaders.contentRangeHeader, 'bytes */$fileLength');
        await response.close();
        return;
      }

      response.statusCode = HttpStatus.partialContent;
      response.headers.add(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$fileLength');
      response.headers.add(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentLength = (end - start) + 1;

      try {
        await file.openRead(start, end + 1).pipe(response);
      } catch (e) {
        debugPrint("Error serving partial file: $e");
        await response.close();
      }
    } else {
      response.headers.add(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentLength = fileLength;
      try {
        await file.openRead().pipe(response);
      } catch (e) {
        debugPrint("Error serving file: $e");
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      }
    }
  }

  // ── Share Upload Handler ─────────────────────────────────────────────────
  Future<void> _handleShareUpload(HttpRequest request, HttpResponse response) async {
    final ct = request.headers.contentType;
    if (ct == null || ct.primaryType != 'multipart') {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'Expected multipart/form-data'}));
      await response.close();
      return;
    }
    final boundary = ct.parameters['boundary'];
    if (boundary == null) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    try {
      final transformer = MimeMultipartTransformer(boundary);
      final parts = request.cast<List<int>>().transform(transformer);
      SharedFile? created;

      await for (final part in parts) {
        final disp = part.headers['content-disposition'] ?? '';
        final match = RegExp(r'filename="([^"]+)"').firstMatch(disp);
        if (match != null) {
          final fileName = match.group(1)!;
          // Save to system temp (not the shared directory — share files are separate)
          final tempPath =
              '${Directory.systemTemp.path}${Platform.pathSeparator}wv_share_${DateTime.now().millisecondsSinceEpoch}_$fileName';
          final file = File(tempPath);
          final sink = file.openWrite();
          await part.cast<List<int>>().pipe(sink);
          await sink.close();

          final size = await file.length();
          created = await _shareService.createShare(
            filePath: tempPath,
            fileName: fileName,
            fileSize: size,
          );
        }
      }

      if (created == null) {
        response.statusCode = HttpStatus.badRequest;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'error': 'No file found in request'}));
      } else {
        response.headers.contentType = ContentType.json;
        final serverIp = (await NetworkInterface.list(type: InternetAddressType.IPv4))
            .expand((i) => i.addresses)
            .firstWhere(
              (a) => a.address.startsWith('192.168.') || a.address.startsWith('10.'),
              orElse: () => InternetAddress('localhost'),
            )
            .address;
        final shareUrl = 'http://$serverIp:$port/share/${created.token}';
        response.write(jsonEncode({
          ...created.toJson(),
          'shareUrl': shareUrl,
          'downloadUrl': '$shareUrl/download',
        }));
      }
      await response.close();
    } catch (e) {
      debugPrint('Share upload error: $e');
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'error': e.toString()}));
      await response.close();
    }
  }

  // ── Share Info HTML Page (public, no auth) ──────────────────────────────
  String _buildSharePage(SharedFile share, HttpRequest request) {
    final host = request.headers.host ?? 'localhost';
    final downloadUrl = 'http://$host/share/${share.token}/download';
    final ttlH = share.remainingTtl.inHours;
    final ttlM = share.remainingTtl.inMinutes % 60;
    final ttlStr = ttlH > 0 ? '${ttlH}h ${ttlM}m' : '${ttlM}m';
    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WiFi Vault — ${share.fileName}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:'Segoe UI',system-ui,sans-serif}
body{min-height:100vh;background:#0f172a;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:rgba(30,41,59,0.9);border:1px solid rgba(255,255,255,0.1);border-radius:24px;padding:40px;max-width:480px;width:100%;text-align:center;backdrop-filter:blur(12px)}
.icon{font-size:64px;margin-bottom:16px}
h1{font-size:22px;color:#f8fafc;font-weight:700;margin-bottom:8px;word-break:break-all}
.meta{color:#94a3b8;font-size:14px;margin-bottom:24px}
.stat{display:inline-block;background:rgba(59,130,246,0.1);border:1px solid rgba(59,130,246,0.3);border-radius:8px;padding:8px 16px;margin:4px;font-size:13px;color:#60a5fa}
.ttl{display:inline-block;background:rgba(245,158,11,0.1);border:1px solid rgba(245,158,11,0.3);border-radius:8px;padding:8px 16px;margin:4px;font-size:13px;color:#fbbf24}
.btn{display:block;width:100%;margin-top:24px;padding:16px;background:linear-gradient(135deg,#3b82f6,#8b5cf6);color:white;text-decoration:none;border-radius:12px;font-size:18px;font-weight:700;transition:.2s}
.btn:hover{opacity:.9;transform:translateY(-2px)}
.info{margin-top:16px;font-size:12px;color:#475569}
</style>
</head>
<body>
<div class="card">
  <div class="icon">📦</div>
  <h1>${share.fileName}</h1>
  <p class="meta">Shared via WiFi Vault</p>
  <span class="stat">📁 ${SharedFile.fmtBytes(share.fileSize)}</span>
  <span class="stat">⬇️ ${share.downloadCount} downloads</span>
  <span class="ttl">⏱ Expires in $ttlStr</span>
  <a class="btn" href="$downloadUrl">⬇️ Download File</a>
  <p class="info">This link is valid for 24 hours from creation.<br>Anyone with this link can download the file.</p>
</div>
</body></html>''';
  }

  String _buildExpiredPage() => '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WiFi Vault — Link Expired</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:'Segoe UI',system-ui,sans-serif}
body{min-height:100vh;background:#0f172a;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:rgba(30,41,59,0.9);border:1px solid rgba(239,68,68,0.3);border-radius:24px;padding:40px;max-width:400px;width:100%;text-align:center}
h1{font-size:22px;color:#ef4444;margin:16px 0 8px}
p{color:#94a3b8;font-size:15px}
</style>
</head>
<body>
<div class="card">
  <div style="font-size:64px">⏰</div>
  <h1>Link Expired</h1>
  <p>This share link has expired or no longer exists.<br>Ask the sender to create a new share.</p>
</div>
</body></html>''';
}

