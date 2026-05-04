import 'dart:io';
import 'dart:async';

class ScanResult {
  final String ip;
  final bool isAlive;
  final String hostname;
  final int responseMs;

  const ScanResult({
    required this.ip,
    required this.isAlive,
    required this.hostname,
    required this.responseMs,
  });

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'isAlive': isAlive,
        'hostname': hostname,
        'responseMs': responseMs,
      };
}

class ScannerService {
  /// Derives the /24 subnet from [localIp] and concurrently probes all 254 hosts.
  /// Uses TCP connect: if the OS returns "Connection refused" the host IS alive
  /// (its IP stack replied with RST). A timeout means the host is unreachable.
  static Future<List<ScanResult>> scanSubnet(String localIp) async {
    final parts = localIp.split('.');
    if (parts.length != 4) return [];

    final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
    final futures = List.generate(254, (i) => _probeHost('$subnet.${i + 1}'));
    final results = await Future.wait(futures);
    return results.where((r) => r.isAlive).toList()
      ..sort((a, b) {
        final aLast = int.tryParse(a.ip.split('.').last) ?? 0;
        final bLast = int.tryParse(b.ip.split('.').last) ?? 0;
        return aLast.compareTo(bLast);
      });
  }

  static Future<ScanResult> _probeHost(String ip) async {
    final sw = Stopwatch()..start();
    bool isAlive = false;

    // Probe common ports. "Connection refused" = host alive, port closed.
    for (final port in [80, 443, 22, 8080, 445, 135]) {
      try {
        final socket =
            await Socket.connect(ip, port, timeout: const Duration(milliseconds: 500));
        socket.destroy();
        isAlive = true;
        break;
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('connection refused') || msg.contains('econnrefused')) {
          isAlive = true;
          break;
        }
      }
    }

    sw.stop();
    String hostname = '';
    if (isAlive) {
      try {
        final result =
            await InternetAddress(ip).reverse().timeout(const Duration(seconds: 1));
        hostname = result.host == ip ? '' : result.host;
      } catch (_) {}
    }

    return ScanResult(
      ip: ip,
      isAlive: isAlive,
      hostname: hostname,
      responseMs: sw.elapsedMilliseconds,
    );
  }
}
