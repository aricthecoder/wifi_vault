import 'dart:io';
import 'package:mime/mime.dart';
import 'dart:math';
import 'dart:convert';
import 'web_ui.dart';
import 'package:archive/archive_io.dart';

class ServerService {
  HttpServer? _server;
  final String sharedDirectoryPath;
  final String pin;
  final Function(String) onLog;
  int port = 8080;

  ServerService(this.sharedDirectoryPath, this.pin, {required this.onLog});

  Future<void> startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      print("Server running on port ${_server!.port}");
      
      _server!.listen((HttpRequest request) {
        _handleRequest(request);
      });
    } catch (e) {
      print("Error starting server: $e");
      rethrow;
    }
  }

  void stopServer() {
    _server?.close(force: true);
    _server = null;
    print("Server stopped");
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
      print("Error handling upload: $e");
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
      print("Error creating zip: $e");
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
      print("Error creating selected zip: $e");
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
        if (sizeBytes <= 0) formattedSize = "0 B";
        else {
          const suffixes = ["B", "KB", "MB", "GB", "TB"];
          var i = (log(sizeBytes) / log(1024)).floor();
          formattedSize = ((sizeBytes / pow(1024, i)).toStringAsFixed(1)) + ' ' + suffixes[i];
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
        print("Error serving partial file: $e");
        await response.close();
      }
    } else {
      response.headers.add(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentLength = fileLength;
      try {
        await file.openRead().pipe(response);
      } catch (e) {
        print("Error serving file: $e");
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      }
    }
  }
}
