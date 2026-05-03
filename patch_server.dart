import 'dart:io';

void main() {
  var file = File('lib/services/server_service.dart');
  var code = file.readAsStringSync();

  // 1. Update _handleRequest to pass `request` to `_serveApiFilesList`
  code = code.replaceFirst(
    'await _serveApiFilesList(response);',
    'await _serveApiFilesList(request, response);'
  );

  // 2. Update _serveApiFilesList
  var startList = code.indexOf('Future<void> _serveApiFilesList');
  var endList = code.indexOf('void _sendNotFound', startList);
  if (startList != -1 && endList != -1) {
    var newServeApiFilesList = '''
  Future<void> _serveApiFilesList(HttpRequest request, HttpResponse response) async {
    String subPath = request.uri.queryParameters['path'] ?? '';
    
    // Security check: Prevent directory traversal
    if (subPath.contains('..') || subPath.startsWith('/') || subPath.startsWith('\\\\')) {
      response.statusCode = HttpStatus.badRequest;
      response.write('[]');
      await response.close();
      return;
    }

    final targetDirPath = subPath.isEmpty 
        ? sharedDirectoryPath 
        : '\$sharedDirectoryPath\${Platform.pathSeparator}\$subPath';
    
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

  ''';
    code = code.replaceRange(startList, endList, newServeApiFilesList);
  }

  // 3. Update _serveFile security check
  var startServeFile = code.indexOf('Future<void> _serveFile');
  var endServeFile = code.indexOf('final file = File(', startServeFile);
  if (startServeFile != -1 && endServeFile != -1) {
    var newServeFileTop = '''
  Future<void> _serveFile(HttpRequest request, HttpResponse response, {bool inline = false}) async {
    final requestedPath = request.uri.queryParameters['path'];
    if (requestedPath == null || requestedPath.contains('..') || requestedPath.startsWith('/') || requestedPath.startsWith('\\\\')) {
       _sendNotFound(response);
       return;
    }

    ''';
    code = code.replaceRange(startServeFile, endServeFile, newServeFileTop);
  }

  // 4. Update _handleDownloadSelectedZip path validation
  code = code.replaceFirst(
    "if (name.contains('..') || name.contains('/') || name.contains('\\\\')) continue;",
    "if (name.contains('..') || name.startsWith('/') || name.startsWith('\\\\')) continue;"
  );

  file.writeAsStringSync(code);
}
