import 'dart:io';
import 'dart:math';
import 'dart:convert';

class SpeedTestService {
  static const int _chunkSize = 65536; // 64 KB

  /// Streams [sizeMb] megabytes of random data to measure download throughput.
  static Future<void> handleDownload(
      HttpRequest request, HttpResponse response, int sizeMb) async {
    final totalBytes = sizeMb * 1024 * 1024;
    final random = Random();

    response.headers.contentType = ContentType('application', 'octet-stream');
    response.headers.add('Cache-Control', 'no-store');
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.contentLength = totalBytes;

    int sent = 0;
    try {
      while (sent < totalBytes) {
        final chunk = min(_chunkSize, totalBytes - sent);
        response.add(List.generate(chunk, (_) => random.nextInt(256)));
        sent += chunk;
        await response.flush();
      }
    } catch (_) {}
    await response.close();
  }

  /// Reads the entire request body and returns throughput metrics.
  static Future<Map<String, dynamic>> handleUpload(HttpRequest request) async {
    final sw = Stopwatch()..start();
    int bytes = 0;
    try {
      await for (final chunk in request) {
        bytes += chunk.length;
      }
    } catch (_) {}
    sw.stop();

    final ms = sw.elapsedMilliseconds;
    final mbps = ms > 0 ? (bytes * 8.0) / (ms * 1000.0) : 0.0;

    return {
      'receivedBytes': bytes,
      'durationMs': ms,
      'mbps': double.parse(mbps.toStringAsFixed(2)),
    };
  }

  /// Tiny ping endpoint — just returns empty JSON; RTT is measured client-side.
  static void handlePing(HttpResponse response) {
    response.headers.contentType = ContentType.json;
    response.headers.add('Cache-Control', 'no-store');
    response.write(jsonEncode({'pong': true, 'ts': DateTime.now().millisecondsSinceEpoch}));
    response.close();
  }
}
