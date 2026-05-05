import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';

class DiscoveredVault {
  final String ip;
  final int port;
  final DateTime lastSeen;

  DiscoveredVault(this.ip, this.port, this.lastSeen);
}

class DiscoveryService {
  static const int _broadcastPort = 8081;
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  bool _isRunning = false;

  final Map<String, DiscoveredVault> _discoveredVaults = {};
  final StreamController<List<DiscoveredVault>> _vaultsController = StreamController<List<DiscoveredVault>>.broadcast();

  Stream<List<DiscoveredVault>> get vaultsStream => _vaultsController.stream;

  Future<void> start(String localIp, int serverPort) async {
    if (_isRunning) return;
    _isRunning = true;

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _broadcastPort, reuseAddress: true, reusePort: true);
      _socket!.broadcastEnabled = true;

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? datagram = _socket!.receive();
          if (datagram != null) {
            String message = utf8.decode(datagram.data);
            if (message.startsWith('WIFI_VAULT:')) {
              final parts = message.split(':');
              if (parts.length == 3) {
                final ip = parts[1];
                final port = int.tryParse(parts[2]);
                if (port != null && ip != localIp) {
                  _discoveredVaults[ip] = DiscoveredVault(ip, port, DateTime.now());
                  _cleanupOldVaults();
                  _vaultsController.add(_discoveredVaults.values.toList());
                }
              }
            }
          }
        }
      });

      _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        final message = 'WIFI_VAULT:$localIp:$serverPort';
        final data = utf8.encode(message);
        
        try {
          // Send to global broadcast
          _socket!.send(data, InternetAddress('255.255.255.255'), _broadcastPort);
        } catch (e) {
          debugPrint("Broadcast error (255.255.255.255 failed): $e");
        }

        try {
          // Send to subnet-specific broadcast (e.g. 192.168.1.255)
          final parts = localIp.split('.');
          if (parts.length == 4) {
            parts[3] = '255';
            final subnetBroadcast = parts.join('.');
            _socket!.send(data, InternetAddress(subnetBroadcast), _broadcastPort);
          }
        } catch (e) {
          debugPrint("Broadcast error (subnet failed): $e");
        }
      });
    } catch (e) {
      debugPrint('Discovery Service Error: $e');
    }
  }

  void _cleanupOldVaults() {
    final now = DateTime.now();
    _discoveredVaults.removeWhere((ip, vault) => now.difference(vault.lastSeen).inSeconds > 10);
  }

  void stop() {
    _isRunning = false;
    _broadcastTimer?.cancel();
    _socket?.close();
    _discoveredVaults.clear();
    _vaultsController.add([]);
  }
}
