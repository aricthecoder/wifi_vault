import 'dart:io';

class StatsService {
  static final StatsService _instance = StatsService._();
  factory StatsService() => _instance;
  StatsService._();

  final DateTime _startTime = DateTime.now();
  int _totalRequests = 0;
  int _bytesIn = 0;
  int _bytesOut = 0;
  final Set<String> _uniqueClients = {};
  final List<DateTime> _requestLog = [];

  void recordRequest(HttpRequest request) {
    _totalRequests++;
    final ip = request.connectionInfo?.remoteAddress.address ?? '';
    if (ip.isNotEmpty) _uniqueClients.add(ip);
    _requestLog.add(DateTime.now());
    // Keep only last 5 min
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    _requestLog.removeWhere((t) => t.isBefore(cutoff));
  }

  void recordBytesOut(int bytes) => _bytesOut += bytes;
  void recordBytesIn(int bytes) => _bytesIn += bytes;

  Map<String, dynamic> getStats() {
    final uptime = DateTime.now().difference(_startTime);
    final oneMinAgo = DateTime.now().subtract(const Duration(minutes: 1));
    return {
      'uptime': _fmt(uptime),
      'uptimeSeconds': uptime.inSeconds,
      'totalRequests': _totalRequests,
      'bytesIn': _bytesIn,
      'bytesOut': _bytesOut,
      'bytesInFormatted': _fmtBytes(_bytesIn),
      'bytesOutFormatted': _fmtBytes(_bytesOut),
      'uniqueClients': _uniqueClients.length,
      'clientIps': _uniqueClients.toList(),
      'requestsPerMin': _requestLog.where((t) => t.isAfter(oneMinAgo)).length,
    };
  }

  void reset() {
    _totalRequests = 0;
    _bytesIn = 0;
    _bytesOut = 0;
    _uniqueClients.clear();
    _requestLog.clear();
  }

  String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(1)} GB';
  }
}
