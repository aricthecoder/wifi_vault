import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../services/server_service.dart';
import '../services/discovery_service.dart';
import '../utils/network_utils.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _selectedDirectoryPath;
  String? _localIp;
  ServerService? _serverService;
  bool _isServerRunning = false;
  String? _currentPin;
  final List<String> _serverLogs = [];
  DiscoveryService? _discoveryService;
  List<DiscoveredVault> _nearbyVaults = [];

  @override
  void initState() {
    super.initState();
    _fetchLocalIp();
    _discoveryService = DiscoveryService();
    _discoveryService!.vaultsStream.listen((vaults) {
      if (mounted) {
        setState(() {
          _nearbyVaults = vaults;
        });
      }
    });
  }

  Future<void> _fetchLocalIp() async {
    final ip = await NetworkUtils.getLocalIpAddress();
    setState(() {
      _localIp = ip;
    });
  }

  Future<void> _pickDirectory() async {
    bool hasPermission = await NetworkUtils.requestPermissions();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Storage permission is required to share files')),
        );
      }
      return;
    }

    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

    if (selectedDirectory != null) {
      setState(() {
        _selectedDirectoryPath = selectedDirectory;
      });
    }
  }

  void _toggleServer() async {
    if (_isServerRunning) {
      _serverService?.stopServer();
      _discoveryService?.stop();
      setState(() {
        _isServerRunning = false;
        _serverLogs.clear();
      });
    } else {
      if (_selectedDirectoryPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a directory first')),
        );
        return;
      }

      if (_localIp == null) {
        await _fetchLocalIp();
        if (_localIp == null) {
           if (mounted) {
             ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Could not get local IP address. Please check your WiFi connection.')),
             );
           }
           return;
        }
      }

      final random = Random();
      final pin = (1000 + random.nextInt(9000)).toString();

      _serverService = ServerService(_selectedDirectoryPath!, pin, onLog: (msg) {
        if (mounted) {
          setState(() {
            final time = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}";
            _serverLogs.insert(0, "[$time] $msg");
            if (_serverLogs.length > 50) _serverLogs.removeLast();
          });
        }
      });
      
      try {
        await _serverService!.startServer();
        _discoveryService!.start(_localIp!, _serverService!.port);
        setState(() {
          _isServerRunning = true;
          _currentPin = pin;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to start server: $e')),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _serverService?.stopServer();
    _discoveryService?.stop();
    super.dispose();
  }

  Future<void> _sendFileToVault(DiscoveredVault vault) async {
    String? peerPin;
    await showDialog(
      context: context,
      builder: (context) {
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Connect to ${vault.ip}'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: const InputDecoration(
              hintText: "Enter 4-digit PIN",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text('Cancel', style: TextStyle(color: Colors.grey))
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
              onPressed: () { peerPin = ctrl.text; Navigator.pop(context); }, 
              child: const Text('Connect')
            ),
          ],
        );
      }
    );

    if (peerPin == null || peerPin!.isEmpty) return;

    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;

    File file = File(result.files.single.path!);
    
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sending to ${vault.ip}...')));

    try {
      var request = http.MultipartRequest('POST', Uri.parse('http://${vault.ip}:${vault.port}/api/upload'));
      request.headers['X-Vault-Pin'] = peerPin!;
      request.files.add(await http.MultipartFile.fromPath('file', file.path));

      var response = await request.send().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('Connection timed out.'),
      );
      if (mounted) {
        if (response.statusCode == 200 || response.statusCode == 303 || response.statusCode == 302) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File sent successfully!')));
        } else {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed: Incorrect PIN.')));
        }
      }
    } catch (e) {
      if (mounted) {
        String errMsg = e.toString();
        if (e is TimeoutException || errMsg.contains('timed out') || errMsg.contains('SocketException')) {
           errMsg = 'Connection failed. Ensure both devices are on the exact same Wi-Fi and the vault is active.';
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errMsg)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = _isServerRunning && _localIp != null 
        ? 'http://$_localIp:${_serverService!.port}' 
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: 32),
              _buildDirectoryCard(),
              const SizedBox(height: 24),
              _buildToggleServerButton(),
              const SizedBox(height: 32),
              
              if (_isServerRunning && serverUrl != null) ...[
                _buildPinCard(),
                const SizedBox(height: 24),
                _buildQrCard(serverUrl),
                const SizedBox(height: 32),
                _buildTransferSection(),
                const SizedBox(height: 32),
                _buildTerminalLogs(),
                const SizedBox(height: 40),
              ] else ...[
                const SizedBox(height: 60),
                Center(
                  child: Column(
                    children: [
                      Icon(Icons.wifi_lock, size: 80, color: Colors.grey.withValues(alpha: 0.2)),
                      const SizedBox(height: 16),
                      Text(
                        'Server Offline',
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 18),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Local IP: ${_localIp ?? "Detecting..."}',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'WiFi Vault',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isServerRunning ? Colors.greenAccent : Colors.grey,
                      boxShadow: _isServerRunning ? [
                        BoxShadow(color: Colors.greenAccent.withValues(alpha: 0.5), blurRadius: 8)
                      ] : [],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isServerRunning ? 'Active on Network' : 'Disconnected',
                      style: TextStyle(
                        color: _isServerRunning ? Colors.greenAccent : Colors.grey,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.cloud_sync, color: Colors.blueAccent),
        )
      ],
    );
  }

  Widget _buildDirectoryCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_shared, color: Colors.blueAccent, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Shared Folder',
                style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  _selectedDirectoryPath != null 
                    ? _selectedDirectoryPath!.split(Platform.pathSeparator).last 
                    : 'Tap to select folder...',
                  style: TextStyle(
                    color: _selectedDirectoryPath != null ? Colors.white : Colors.white38,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: _isServerRunning ? null : _pickDirectory,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _isServerRunning ? Colors.transparent : Colors.blueAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.edit, 
                    color: _isServerRunning ? Colors.grey : Colors.blueAccent, 
                    size: 20
                  ),
                ),
              )
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggleServerButton() {
    return GestureDetector(
      onTap: _toggleServer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _isServerRunning 
              ? [Colors.redAccent, Colors.deepOrange]
              : [const Color(0xFF3B82F6), const Color(0xFF8B5CF6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: (_isServerRunning ? Colors.redAccent : const Color(0xFF3B82F6)).withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(0, 8),
            )
          ]
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_isServerRunning ? Icons.power_settings_new : Icons.rocket_launch, color: Colors.white),
            const SizedBox(width: 12),
            Text(
              _isServerRunning ? 'Stop Server' : 'Launch Server',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPinCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          const Text('SECURITY PIN', style: TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 8),
          Text(
            _currentPin ?? '----',
            style: const TextStyle(
              fontSize: 40,
              letterSpacing: 12,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildQrCard(String serverUrl) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Text(
            'Scan to connect from any device',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: QrImageView(
              data: serverUrl,
              version: QrVersions.auto,
              size: 180.0,
            ),
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: serverUrl));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('URL copied to clipboard')));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      serverUrl,
                      style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w600, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Icon(Icons.copy, color: Colors.blueAccent, size: 18),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Future<void> _showManualConnectDialog() async {
    String? ipAddress;
    await showDialog(
      context: context,
      builder: (context) {
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Connect Manually'),
          content: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              hintText: "Enter IP (e.g. 192.168.1.5)",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text('Cancel', style: TextStyle(color: Colors.grey))
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
              onPressed: () { ipAddress = ctrl.text.trim(); Navigator.pop(context); }, 
              child: const Text('Next')
            ),
          ],
        );
      }
    );

    if (ipAddress != null && ipAddress!.isNotEmpty) {
      _sendFileToVault(DiscoveredVault(ipAddress!, 8080, DateTime.now()));
    }
  }

  Widget _buildTransferSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  const Icon(Icons.radar, color: Colors.purpleAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'App-to-App Transfer',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: _showManualConnectDialog,
              icon: const Icon(Icons.add_link, color: Colors.purpleAccent, size: 16),
              label: const Text('Manual IP', style: TextStyle(color: Colors.purpleAccent)),
            )
          ],
        ),
        const SizedBox(height: 16),
        if (_nearbyVaults.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.purpleAccent.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.1)),
            ),
            child: const Center(
              child: Text('No vaults found automatically.', style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic)),
            ),
          )
        else
          ..._nearbyVaults.map((vault) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.purpleAccent.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.3)),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.purpleAccent.withValues(alpha: 0.2), shape: BoxShape.circle),
                child: const Icon(Icons.phone_android, color: Colors.purpleAccent),
              ),
              title: Text(vault.ip, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              subtitle: const Text('Tap to send file', style: TextStyle(color: Colors.white54)),
              trailing: IconButton(
                icon: const Icon(Icons.send_rounded, color: Colors.purpleAccent),
                onPressed: () => _sendFileToVault(vault),
              ),
            ),
          )),
      ],
    );
  }

  Widget _buildTerminalLogs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Live Logs',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white70),
        ),
        const SizedBox(height: 12),
        Container(
          height: 180,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF020617), // Deep black
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: _serverLogs.isEmpty
            ? const Center(
                child: Text('Waiting for activity...', style: TextStyle(color: Colors.white24, fontStyle: FontStyle.italic)),
              )
            : ListView.builder(
                itemCount: _serverLogs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6.0),
                    child: Text(
                      "> ${_serverLogs[index]}",
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  );
                },
              ),
        ),
      ],
    );
  }
}
