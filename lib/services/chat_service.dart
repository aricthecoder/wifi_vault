import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';

class ChatService {
  final List<WebSocket> _clients = [];
  final List<Map<String, dynamic>> _history = [];

  int get clientCount => _clients.length;

  /// Upgrades an [HttpRequest] to a WebSocket connection and registers the client.
  Future<void> handleUpgrade(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    final senderIp = request.connectionInfo?.remoteAddress.address ?? 'Unknown';
    _clients.add(socket);

    // Send existing history to the newly connected client
    for (final msg in _history) {
      socket.add(jsonEncode(msg));
    }

    _broadcastSystem('$senderIp joined the vault chat', exclude: socket);

    socket.listen(
      (data) {
        try {
          final decoded = jsonDecode(data as String) as Map<String, dynamic>;
          final text = (decoded['text'] as String? ?? '').trim();
          if (text.isEmpty) return;

          final msg = {
            'type': 'message',
            'sender': senderIp,
            'text': text,
            'timestamp': DateTime.now().toIso8601String(),
          };

          if (_history.length >= 100) _history.removeAt(0);
          _history.add(msg);
          _broadcast(jsonEncode(msg));
        } catch (e) {
          debugPrint('Chat parse error: $e');
        }
      },
      onDone: () {
        _clients.remove(socket);
        _broadcastSystem('$senderIp left the chat');
      },
      onError: (_) => _clients.remove(socket),
      cancelOnError: true,
    );
  }

  void _broadcast(String message, {WebSocket? exclude}) {
    final dead = <WebSocket>[];
    for (final client in _clients) {
      if (client == exclude) continue;
      try {
        client.add(message);
      } catch (_) {
        dead.add(client);
      }
    }
    _clients.removeWhere(dead.contains);
  }

  void _broadcastSystem(String text, {WebSocket? exclude}) {
    _broadcast(
      jsonEncode({
        'type': 'system',
        'text': text,
        'timestamp': DateTime.now().toIso8601String(),
      }),
      exclude: exclude,
    );
  }

  void dispose() {
    for (final c in _clients) {
      c.close();
    }
    _clients.clear();
    _history.clear();
  }
}
