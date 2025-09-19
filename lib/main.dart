import 'package:flutter/material.dart';
import 'package:flutter_serial_communication/flutter_serial_communication.dart';
import 'package:flutter_serial_communication/models/device_info.dart';
import 'dart:typed_data';
import 'dart:async';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BMH05108 Arms Body Composition Monitor',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: BMH05108Screen(),
    );
  }
}

class BMH05108Screen extends StatefulWidget {
  const BMH05108Screen({super.key});

  @override
  BMH05108ScreenState createState() => BMH05108ScreenState();
}

class BMH05108ScreenState extends State<BMH05108Screen> {
  final FlutterSerialCommunication _serialCommunication =
      FlutterSerialCommunication();
  List<DeviceInfo> _availableDevices = [];
  DeviceInfo? _selectedDevice;
  bool _isConnected = false;
  String _log = '';
  Timer? _measurementTimer;
  StreamSubscription<dynamic>? _messageSubscription;
  StreamSubscription<dynamic>? _connectionSubscription;

  // Arms impedance data
  final Map<String, double> _impedanceData = {
    'rightHand20kHz': 0.0,
    'leftHand20kHz': 0.0,
    'rightHand100kHz': 0.0,
    'leftHand100kHz': 0.0,
  };

  String _impedanceStatus = 'Not Ready';
  bool _isMeasuring = false;
  String _deviceVersion = 'Unknown';

  @override
  void initState() {
    super.initState();
    _scanForDevices();
  }

  @override
  void dispose() {
    _measurementTimer?.cancel();
    _messageSubscription?.cancel();
    _connectionSubscription?.cancel();
    _disconnectDevice();
    super.dispose();
  }

  Future<void> _scanForDevices() async {
    try {
      List<DeviceInfo> devices = await _serialCommunication
          .getAvailableDevices();
      setState(() {
        _availableDevices = devices;
      });
      _addLog('Found ${devices.length} devices');
      for (var device in devices) {
        _addLog('Device: ${device.deviceName} (${device.manufacturerName})');
      }
    } catch (e) {
      _addLog('Error scanning devices: $e');
    }
  }

  Future<void> _connectToDevice() async {
    if (_selectedDevice == null) {
      _addLog('Please select a device first');
      return;
    }

    try {
      bool connected = await _serialCommunication.connect(
        _selectedDevice!,
        38400,
      );

      if (connected) {
        setState(() {
          _isConnected = true;
        });

        _addLog('Connected to ${_selectedDevice!.deviceName}');

        // Setup listeners
        _setupListeners();

        // Get device version
        await Future.delayed(Duration(milliseconds: 500));
        _getDeviceVersion();
      } else {
        _addLog('Failed to connect to device');
      }
    } catch (e) {
      _addLog('Connection error: $e');
    }
  }

  void _setupListeners() {
    // Listen for incoming serial data
    _messageSubscription = _serialCommunication
        .getSerialMessageListener()
        .receiveBroadcastStream()
        .listen(
          (data) {
            if (data is List<int>) {
              _handleReceivedData(Uint8List.fromList(data));
            }
          },
          onError: (error) {
            _addLog('Message listener error: $error');
          },
        );

    // Listen for connection status changes
    _connectionSubscription = _serialCommunication
        .getDeviceConnectionListener()
        .receiveBroadcastStream()
        .listen(
          (connectionStatus) {
            _addLog('Connection status: $connectionStatus');
            if (connectionStatus == false || connectionStatus == 'false') {
              setState(() {
                _isConnected = false;
                _isMeasuring = false;
              });
              _measurementTimer?.cancel();
            }
          },
          onError: (error) {
            _addLog('Connection listener error: $error');
          },
        );
  }

  Future<void> _disconnectDevice() async {
    try {
      _measurementTimer?.cancel();
      _messageSubscription?.cancel();
      _connectionSubscription?.cancel();

      await _serialCommunication.disconnect();

      setState(() {
        _isConnected = false;
        _selectedDevice = null;
        _isMeasuring = false;
      });
      _addLog('Disconnected from device');
    } catch (e) {
      _addLog('Disconnect error: $e');
    }
  }

  void _handleReceivedData(Uint8List data) {
    _addLog(
      'Raw data: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
    );

    if (data.length < 3) return;

    // Check frame header and command
    if (data[0] == 0xAA) {
      // Response from device
      int command = data[2];

      switch (command) {
        case 0xB0: // Impedance mode switch response
          _parseImpedanceModeResponse(data);
          break;
        case 0xB1: // Impedance status response
          _parseImpedanceStatus(data);
          break;
        case 0xE0: // Version response
          _parseVersionResponse(data);
          break;
        default:
          _addLog('Unknown response command: 0x${command.toRadixString(16)}');
      }
    }
  }

  void _parseImpedanceModeResponse(Uint8List data) {
    if (data.length < 5) return;

    int result = data[3];
    String resultText = '';
    switch (result) {
      case 0x00:
        resultText = 'Switch OK';
        break;
      case 0x01:
        resultText = 'Working mode error';
        break;
      case 0x02:
        resultText = 'Frequency error';
        break;
      default:
        resultText = 'Unknown result';
    }

    _addLog('Impedance mode switch: $resultText');
  }

  void _parseImpedanceStatus(Uint8List data) {
    if (data.length < 13) return; // Minimum length for four-electrode response

    int measurementFreq = data[3];
    int impedanceState = data[4];
    int dataType = data[5];

    setState(() {
      _impedanceStatus = _getImpedanceStatusText(impedanceState);
    });

    if (impedanceState == 0x03 && data.length >= 13) {
      // Measurement successful
      // Parse four-electrode TwoArms impedance data
      // For TwoArms mode, we get phase angle and impedance

      // Phase angle (bytes 6-7, int16_t, magnified 10 times)
      int phaseAngleRaw = (data[7] << 8) | data[6];
      double phaseAngle = phaseAngleRaw / 10.0;

      // Impedance (bytes 8-11, uint32_t, resolution 1Ω)
      int impedanceRaw =
          (data[11] << 24) | (data[10] << 16) | (data[9] << 8) | data[8];
      double impedance = impedanceRaw.toDouble();

      // For arms measurement, we'll store this as combined arms impedance
      String freqKey = _getFrequencyString(measurementFreq);
      if (freqKey.isNotEmpty) {
        setState(() {
          // Store the impedance value for both arms (since it's a combined measurement)
          _impedanceData['rightHand$freqKey'] = impedance;
          _impedanceData['leftHand$freqKey'] = impedance;
        });

        _addLog(
          'Arms impedance ($freqKey): ${impedance.toStringAsFixed(1)}Ω, Phase: ${phaseAngle.toStringAsFixed(1)}°',
        );
      }
    }
  }

  String _getFrequencyString(int freq) {
    switch (freq) {
      case 0x03:
        return '20kHz';
      case 0x05:
        return '50kHz';
      case 0x06:
        return '100kHz';
      default:
        return '';
    }
  }

  void _parseVersionResponse(Uint8List data) {
    if (data.length >= 6) {
      int app = data[3];
      int version = (data[5] << 8) | data[4];
      String appName = app == 0x00
          ? 'Master'
          : (app == 0x01 ? 'Bia' : 'Weight');
      String versionString = 'v${(version >> 8)}.${version & 0xFF}';

      setState(() {
        _deviceVersion = '$appName: $versionString';
      });

      _addLog('Version - $appName: $versionString');
    }
  }

  String _getImpedanceStatusText(int status) {
    switch (status) {
      case 0x00:
        return 'NULL';
      case 0x01:
        return 'Checking Electrodes';
      case 0x02:
        return 'Measuring';
      case 0x03:
        return 'Success';
      case 0x04:
        return 'Range Error';
      case 0x05:
        return 'Repeat Error';
      case 0x06:
        return 'User Exit';
      default:
        return 'Unknown';
    }
  }

  void _getDeviceVersion() {
    // Get Master version: 55 05 E0 00 C6
    Uint8List command = Uint8List.fromList([0x55, 0x05, 0xE0, 0x00, 0xC6]);
    _sendCommand(command, 'Get Version');
  }

  void _startArmsImpedanceMeasurement() {
    // Four-electrode TwoArms 50kHz measurement: 55 06 B0 03 05 ED
    Uint8List command = Uint8List.fromList([
      0x55,
      0x06,
      0xB0,
      0x03,
      0x05,
      0xED,
    ]);
    _sendCommand(command, 'Start Arms Impedance Measurement (50kHz)');

    setState(() {
      _isMeasuring = true;
    });

    // Start periodic impedance status requests
    _measurementTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (_isConnected && _isMeasuring) {
        _requestArmsImpedanceStatus();
      }
    });
  }

  void _requestArmsImpedanceStatus() {
    // Request 50kHz raw impedance for TwoArms: 55 05 B1 51 A4
    Uint8List command = Uint8List.fromList([0x55, 0x05, 0xB1, 0x51, 0xA4]);
    _sendCommand(command, 'Request Arms Impedance Status');
  }

  void _stopImpedanceMeasurement() {
    // Stop current test: 55 06 B0 00 00 F5
    Uint8List command = Uint8List.fromList([
      0x55,
      0x06,
      0xB0,
      0x00,
      0x00,
      0xF5,
    ]);
    _sendCommand(command, 'Stop Impedance Measurement');

    _measurementTimer?.cancel();
    setState(() {
      _isMeasuring = false;
    });
  }

  void _testBodyCompositionAlgorithm() {
    // Test with sample data for TwoArms algorithm (0xD2)
    // Gender: Male(1), UserType: Normal(0), Height: 172cm, Age: 23, Weight: 62.3kg, Arms impedance: 758Ω
    List<int> command = [
      0x55, 0x0C, 0xD2, // Header, length, command
      0x01, // Gender (Male)
      0x00, // User type (Normal)
      0xAC, // Height (172cm)
      0x17, // Age (23)
      0x6F, 0x02, // Weight (623 = 62.3kg)
      0xF6, 0x02, // Arms impedance (758Ω)
    ];

    // Calculate checksum
    int checksum = 0;
    for (int i = 0; i < command.length; i++) {
      checksum += command[i];
    }
    checksum = (~checksum + 1) & 0xFF;
    command.add(checksum);

    _sendCommand(
      Uint8List.fromList(command),
      'Test Body Composition Algorithm',
    );
  }

  Future<void> _sendCommand(Uint8List command, String description) async {
    if (!_isConnected) {
      _addLog('Device not connected');
      return;
    }

    try {
      bool sent = await _serialCommunication.write(command);
      if (sent) {
        _addLog(
          '$description sent: ${command.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
        );
      } else {
        _addLog('Failed to send $description');
      }
    } catch (e) {
      _addLog('Error sending $description: $e');
    }
  }

  void _addLog(String message) {
    setState(() {
      String timestamp = DateTime.now().toString().substring(11, 19);
      _log += '$timestamp: $message\n';
    });
    print(message);
  }

  void _clearLog() {
    setState(() {
      _log = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('BMH05108 Arms Monitor'),
        backgroundColor: Colors.blue[700],
      ),
      body: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Connection Section
            Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Connection',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<DeviceInfo>(
                            hint: Text('Select Device'),
                            value: _selectedDevice,
                            items: _availableDevices.map((device) {
                              return DropdownMenuItem(
                                value: device,
                                child: Text(
                                  '${device.deviceName} (${device.manufacturerName})',
                                ),
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedDevice = value;
                              });
                            },
                          ),
                        ),
                        SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: _scanForDevices,
                          child: Text('Scan'),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: _isConnected ? null : _connectToDevice,
                          child: Text('Connect'),
                        ),
                        SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: _isConnected ? _disconnectDevice : null,
                          child: Text('Disconnect'),
                        ),
                        SizedBox(width: 10),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _isConnected ? Colors.green : Colors.red,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _isConnected ? 'Connected' : 'Disconnected',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    if (_deviceVersion != 'Unknown')
                      Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Device: $_deviceVersion',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Control Buttons
            Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Controls',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        ElevatedButton(
                          onPressed: _isConnected ? _getDeviceVersion : null,
                          child: Text('Get Version'),
                        ),
                        ElevatedButton(
                          onPressed: (_isConnected && !_isMeasuring)
                              ? _startArmsImpedanceMeasurement
                              : null,
                          child: Text('Start Arms Measurement'),
                        ),
                        ElevatedButton(
                          onPressed: (_isConnected && _isMeasuring)
                              ? _stopImpedanceMeasurement
                              : null,
                          child: Text('Stop Measurement'),
                        ),
                        ElevatedButton(
                          onPressed: _isConnected
                              ? _testBodyCompositionAlgorithm
                              : null,
                          child: Text('Test Algorithm'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Data Display
            Card(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Arms Impedance Measurements',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 10),

                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey[300]!),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Status: $_impedanceStatus',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                              if (_isMeasuring)
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.orange,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    'MEASURING',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          SizedBox(height: 12),
                          Text(
                            'Instructions:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            '• Hold both hand electrodes firmly',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                            ),
                          ),
                          Text(
                            '• Keep arms extended and slightly away from body',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                            ),
                          ),
                          Text(
                            '• Remain still during measurement',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                            ),
                          ),
                          SizedBox(height: 12),
                          GridView.count(
                            shrinkWrap: true,
                            physics: NeverScrollableScrollPhysics(),
                            crossAxisCount: 2,
                            childAspectRatio: 2.5,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            children: [
                              _buildImpedanceCard(
                                'Right Hand',
                                '20kHz',
                                _impedanceData['rightHand20kHz'] ?? 0.0,
                              ),
                              _buildImpedanceCard(
                                'Left Hand',
                                '20kHz',
                                _impedanceData['leftHand20kHz'] ?? 0.0,
                              ),
                              _buildImpedanceCard(
                                'Right Hand',
                                '50kHz',
                                _impedanceData['rightHand50kHz'] ?? 0.0,
                              ),
                              _buildImpedanceCard(
                                'Left Hand',
                                '50kHz',
                                _impedanceData['leftHand50kHz'] ?? 0.0,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Log Section
            Expanded(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Communication Log',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          ElevatedButton(
                            onPressed: _clearLog,
                            child: Text('Clear'),
                          ),
                        ],
                      ),
                      SizedBox(height: 10),
                      Expanded(
                        child: Container(
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey[300]!),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: SingleChildScrollView(
                            reverse: true,
                            child: Text(
                              _log.isEmpty
                                  ? 'No communication logs yet...'
                                  : _log,
                              style: TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImpedanceCard(String label, String frequency, double value) {
    return Container(
      padding: EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: value > 0 ? Colors.blue[50] : Colors.grey[100],
        border: Border.all(
          color: value > 0 ? Colors.blue[200]! : Colors.grey[300]!,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          ),
          Text(
            frequency,
            style: TextStyle(fontSize: 9, color: Colors.grey[600]),
          ),
          Text(
            '${value.toStringAsFixed(1)}Ω',
            style: TextStyle(
              fontSize: 12,
              color: value > 0 ? Colors.blue[800] : Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
