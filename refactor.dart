import 'dart:io';
import 'dart:math';

void main() {
  var file = File('lib/services/server_service.dart');
  var code = file.readAsStringSync();

  // Add import
  if (!code.contains("import 'web_ui.dart';")) {
    code = code.replaceFirst("import 'dart:convert';", "import 'dart:convert';\nimport 'web_ui.dart';");
  }

  // Find the exact _handleRequest block and replace it
  var startHandleReq = code.indexOf('void _handleRequest(HttpRequest request) async {');
  var endHandleReq = code.indexOf('Future<void> _handleLoginPost', startHandleReq);
  
  if (startHandleReq != -1 && endHandleReq != -1) {
    var newHandleReq = '''
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
          response.headers.add('Set-Cookie', 'vault_pin=\$pin; Path=/; HttpOnly');
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
        await _serveApiFilesList(response);
      } else if (path == '/api/download') {
        final filePathParam = request.uri.queryParameters['path'] ?? 'unknown';
        _log("Downloading: \$filePathParam", request);
        await _serveFile(request, response, inline: false);
      } else if (path == '/api/view') {
        final filePathParam = request.uri.queryParameters['path'] ?? 'unknown';
        _log("Streaming/Viewing: \$filePathParam", request);
        await _serveFile(request, response, inline: true);
      } else {
        _sendNotFound(response);
      }
    } catch (e) {
      _log("Error: \$e", request);
      response.statusCode = HttpStatus.internalServerError;
      response.write("Internal Server Error: \$e");
      await response.close();
    }
  }

''';
    code = code.replaceRange(startHandleReq, endHandleReq, newHandleReq);
  }

  // Delete _handleLoginPost
  var startLoginPost = code.indexOf('Future<void> _handleLoginPost');
  var endLoginPost = code.indexOf('Future<void> _handleUpload', startLoginPost);
  if (startLoginPost != -1 && endLoginPost != -1) {
    code = code.replaceRange(startLoginPost, endLoginPost, '');
  }

  // Update _handleUpload redirect
  code = code.replaceAll(
    "response.statusCode = HttpStatus.seeOther; // 303 Redirect\n      response.headers.set('Location', '/files');",
    "response.statusCode = HttpStatus.ok;"
  );

  // Delete _serveHtml and everything below it except _serveFile
  var startServeHtml = code.indexOf('void _serveHtml');
  var startServeFile = code.indexOf('Future<void> _serveFile', startServeHtml);
  if (startServeHtml != -1 && startServeFile != -1) {
    var newApiFilesList = '''
  Future<void> _serveApiFilesList(HttpResponse response) async {
    final dir = Directory(sharedDirectoryPath);
    if (!dir.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      response.write('[]');
      await response.close();
      return;
    }

    final entities = dir.listSync();
    List<Map<String, String>> filesData = [];

    for (var entity in entities) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
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
          'size': formattedSize
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

''';
    code = code.replaceRange(startServeHtml, startServeFile, newApiFilesList);
  }

  file.writeAsStringSync(code);
}
