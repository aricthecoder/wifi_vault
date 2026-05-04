import 'dart:io';

class WolService {
  static const int _port = 9;

  /// Validates, builds, and broadcasts a WoL magic packet for [macAddress].
  static Future<Map<String, dynamic>> sendMagicPacket(String macAddress) async {
    final cleanMac = macAddress.replaceAll(RegExp(r'[:\-\.]'), '').toUpperCase();

    if (cleanMac.length != 12 || !RegExp(r'^[0-9A-F]{12}$').hasMatch(cleanMac)) {
      return {'success': false, 'error': 'Invalid MAC address. Expected format: AA:BB:CC:DD:EE:FF'};
    }

    // Parse 6 MAC bytes
    final macBytes = <int>[
      for (int i = 0; i < 12; i += 2)
        int.parse(cleanMac.substring(i, i + 2), radix: 16)
    ];

    // Magic packet = 6 × 0xFF + 16 × MAC (= 102 bytes total)
    final packet = <int>[
      ...List.filled(6, 0xFF),
      for (int i = 0; i < 16; i++) ...macBytes,
    ];

    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final targets = [
        InternetAddress('255.255.255.255'),
        InternetAddress('192.168.1.255'),
        InternetAddress('192.168.0.255'),
      ];
      for (final t in targets) {
        socket.send(packet, t, _port);
      }
      socket.close();

      return {
        'success': true,
        'mac': macAddress,
        'packetSize': packet.length,
        'message': 'Magic packet sent to ${targets.length} broadcast addresses',
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }
}
