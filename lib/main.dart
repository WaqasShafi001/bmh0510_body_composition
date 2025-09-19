// main.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_serial_communication/flutter_serial_communication.dart';
import 'package:flutter_serial_communication/models/device_info.dart';

void main() => runApp(MyApp());

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

  // device / state
  List<DeviceInfo> _availableDevices = [];
  DeviceInfo? _selectedDevice;
  bool _isConnected = false;
  String _deviceVersion = 'Unknown';

  // logs
  String _log = '';

  // subscriptions
  StreamSubscription<dynamic>? _messageSubscription;
  StreamSubscription<dynamic>? _connectionSubscription;

  // Impedance measurement timer
  Timer? _measurementTimer;
  bool _isMeasuring = false;
  String _impedanceStatus = 'Not Ready';
  final Map<String, double> _impedanceData = {
    'rightHand20kHz': 0.0,
    'leftHand20kHz': 0.0,
    'rightHand50kHz': 0.0,
    'leftHand50kHz': 0.0,
    'rightHand100kHz': 0.0,
    'leftHand100kHz': 0.0,
  };

  // Algorithm results map (populated when receiving 0xD2)
  Map<String, dynamic> _algorithmResults = {};

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

  // ---------- USB / Serial helpers ----------
  Future<void> _scanForDevices() async {
    try {
      final devices = await _serialCommunication.getAvailableDevices();
      setState(() => _availableDevices = devices);
      _addLog('Found ${devices.length} devices');
      for (var d in devices)
        _addLog('Device: ${d.deviceName} (${d.manufacturerName})');
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
        setState(() => _isConnected = true);
        _addLog('Connected to ${_selectedDevice!.deviceName}');
        _setupListeners();
        await Future.delayed(Duration(milliseconds: 300));
        _getDeviceVersion();
      } else {
        _addLog('Failed to connect');
      }
    } catch (e) {
      _addLog('Connection error: $e');
    }
  }

  Future<void> _disconnectDevice() async {
    try {
      _measurementTimer?.cancel();
      await _serialCommunication.disconnect();
      setState(() {
        _isConnected = false;
        _selectedDevice = null;
        _isMeasuring = false;
      });
      _messageSubscription?.cancel();
      _connectionSubscription?.cancel();
      _addLog('Disconnected from device');
    } catch (e) {
      _addLog('Disconnect error: $e');
    }
  }

  void _setupListeners() {
    _messageSubscription = _serialCommunication
        .getSerialMessageListener()
        .receiveBroadcastStream()
        .listen((data) {
          if (data is List<int>) _handleReceivedData(Uint8List.fromList(data));
        }, onError: (e) => _addLog('Message listener error: $e'));

    _connectionSubscription = _serialCommunication
        .getDeviceConnectionListener()
        .receiveBroadcastStream()
        .listen((status) {
          _addLog('Connection status: $status');
          if (status == false || status == 'false') {
            setState(() {
              _isConnected = false;
              _isMeasuring = false;
            });
            _measurementTimer?.cancel();
          }
        }, onError: (e) => _addLog('Connection listener error: $e'));
  }

  // ---------- Basic commands ----------
  void _getDeviceVersion() {
    // Get Master version: 55 05 E0 00 C6
    final cmd = Uint8List.fromList([0x55, 0x05, 0xE0, 0x00, 0xC6]);
    _sendCommand(cmd, 'Get Version');
  }

  void _startArmsImpedanceMeasurement() {
    // Four-electrode TwoArms 50kHz measurement: 55 06 B0 03 05 ED
    final cmd = Uint8List.fromList([0x55, 0x06, 0xB0, 0x03, 0x05, 0xED]);
    _sendCommand(cmd, 'Start Arms Impedance Measurement (50kHz)');
    setState(() => _isMeasuring = true);
    _measurementTimer?.cancel();
    _measurementTimer = Timer.periodic(Duration(seconds: 1), (_) {
      if (_isConnected && _isMeasuring) _requestArmsImpedanceStatus();
    });
  }

  void _stopImpedanceMeasurement() {
    final cmd = Uint8List.fromList([0x55, 0x06, 0xB0, 0x00, 0x00, 0xF5]);
    _sendCommand(cmd, 'Stop Impedance Measurement');
    _measurementTimer?.cancel();
    setState(() => _isMeasuring = false);
  }

  void _requestArmsImpedanceStatus() {
    // Request 50kHz raw impedance for TwoArms: 55 05 B1 51 A4
    final cmd = Uint8List.fromList([0x55, 0x05, 0xB1, 0x51, 0xA4]);
    _sendCommand(cmd, 'Request Arms Impedance Status');
  }

  void _testBodyCompositionAlgorithm() {
    // TwoArms test input (the same test you used)
    final command = <int>[
      0x55, 0x0C, 0xD2,
      0x01, // gender male
      0x00, // user type normal
      0xAC, // height 172
      0x17, // age 23
      0x6F, 0x02, // weight 623 -> 62.3kg (little-endian)
      0xF6, 0x02, // arms impedance 0x02F6 (758)
    ];
    int checksum = 0;
    for (var b in command) checksum += b;
    checksum = ((~checksum + 1) & 0xFF);
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
          '$description sent: ${command.map((b) => b.toRadixString(16).padLeft(2, "0")).join(' ')}',
        );
      } else {
        _addLog('Failed to send $description');
      }
    } catch (e) {
      _addLog('Error sending $description: $e');
    }
  }

  // ---------- Packet handling ----------
  void _handleReceivedData(Uint8List data) {
    _addLog(
      'Raw data: ${data.map((b) => b.toRadixString(16).padLeft(2, "0")).join(' ')}',
    );
    if (data.length < 3) return;
    if (data[0] != 0xAA) return;

    final cmd = data[2];
    switch (cmd) {
      case 0xB0:
        _parseImpedanceModeResponse(data);
        break;
      case 0xB1:
        _parseImpedanceStatus(data);
        break;
      case 0xE0:
        _parseVersionResponse(data);
        break;
      case 0xD2:
        _parseAlgorithmResponse(data);
        break;
      default:
        _addLog('Unknown response command: 0x${cmd.toRadixString(16)}');
    }
  }

  void _parseImpedanceModeResponse(Uint8List data) {
    if (data.length < 5) return;
    final result = data[3];
    String text = result == 0x00
        ? 'Switch OK'
        : (result == 0x01
              ? 'Working mode error'
              : (result == 0x02 ? 'Frequency error' : 'Unknown'));
    _addLog('Impedance mode switch: $text');
  }

  void _parseImpedanceStatus(Uint8List data) {
    // Format for 4-electrode 50kHz response: AA 0D B1 <freq> <state> <type> <phase(2)> <impedance(4)> <chksum>
    if (data.length < 13) return;
    final freq = data[3];
    final state = data[4];
    final dataType = data[5];
    setState(() => _impedanceStatus = _getImpedanceStatusText(state));

    if (state == 0x03 && data.length >= 13) {
      // phase bytes [6-7] int16 little-endian, magnified 10x
      final phaseRaw = (data[7] << 8) | data[6];
      final phase = phaseRaw / 10.0;
      // impedance bytes [8-11] uint32 little-endian, resolution 1Ω in this response
      final impRaw =
          (data[11] << 24) | (data[10] << 16) | (data[9] << 8) | data[8];
      final imp = impRaw.toDouble();
      final freqKey = _getFrequencyString(freq);
      if (freqKey.isNotEmpty) {
        setState(() {
          _impedanceData['rightHand$freqKey'] = imp;
          _impedanceData['leftHand$freqKey'] = imp;
        });
        _addLog(
          'Arms impedance ($freqKey): ${imp.toStringAsFixed(1)}Ω, Phase: ${phase.toStringAsFixed(1)}°',
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
      final app = data[3];
      final version = (data[5] << 8) | data[4];
      final appName = app == 0x00 ? 'Master' : (app == 0x01 ? 'Bia' : 'Weight');
      final versionString = 'v${(version >> 8)}.${version & 0xFF}';
      setState(() => _deviceVersion = '$appName: $versionString');
      _addLog('Version - $appName: $versionString');
    }
  }

  // ---------- New: full parser for 0xD2 (TwoArms algorithm output) ----------
  void _parseAlgorithmResponse(Uint8List data) {
    // The communication protocol defines many positions in the D1/D2 response packet.
    // We follow the table: byte index relative to data[]:
    // 0: 0xAA, 1: length, 2: 0xD2, 3: pkg info, 4: error type, then fields starting at byte 5.
    if (data.length < 6) {
      _addLog('Algorithm response too short');
      return;
    }

    final errorType = data[4];
    if (errorType != 0x00) {
      _addLog(
        'Algorithm response error type: 0x${errorType.toRadixString(16)}',
      );
      return;
    }

    // We may receive the full multi-package response (length commonly 0x56 in examples).
    // Extract many fields (little-endian). Follow the protocol table for offsets and resolutions.
    // Be defensive with bounds checks.

    final results = <String, dynamic>{};

    int readUInt16LE(int loIndex) {
      if (loIndex + 1 >= data.length) return 0;
      return (data[loIndex] & 0xFF) | ((data[loIndex + 1] & 0xFF) << 8);
    }

    int readUInt8(int idx) => idx < data.length ? data[idx] & 0xFF : 0;

    // offsets from protocol (data[] indexes)
    try {
      // NOTE: the table shows fields starting at byte 5
      // 5~6 fat mass (0.1kg)
      final fatMassRaw = readUInt16LE(5);
      results['Fat mass (kg)'] = fatMassRaw / 10.0;

      // 7~8 fat percentage (0.1%)
      final fatPercentRaw = readUInt16LE(7);
      results['Fat %'] = fatPercentRaw / 10.0;

      // 9 fat rate-standard0 (uint8 -> resolution 0.1)
      results['Fat rate std0'] = readUInt8(9) / 10.0;

      // 10~11 fat percentage - standard1 (0.1)
      results['Fat % std1'] = readUInt16LE(10) / 10.0;

      // 12~13 fat percentage - standard2
      results['Fat % std2'] = readUInt16LE(12) / 10.0;

      // 14~15 fat percentage - standard3
      results['Fat % std3'] = readUInt16LE(14) / 10.0;

      // 16~17 BMI (0.1)
      results['BMI'] = readUInt16LE(16) / 10.0;

      // 18 BMI std0 (0.1), 19 BMI std1 (0.1), 20~21 BMI std2 (0.1)
      results['BMI std0'] = readUInt8(18) / 10.0;
      results['BMI std1'] = readUInt8(19) / 10.0;
      results['BMI std2'] = readUInt16LE(20) / 10.0;

      // 22~23 Basal metabolism (kcal) resolution 1
      results['BMR (kcal)'] = readUInt16LE(22);

      // 24~25 BMR standard0
      results['BMR std0'] = readUInt16LE(24);

      // 26 physical age (years)
      results['Physical age'] = readUInt8(26);

      // 27~28 Lean body mass (0.1kg)
      results['Lean body mass (kg)'] = readUInt16LE(27) / 10.0;

      // 29~30 Subcutaneous fat mass (0.1kg)
      results['Subcutaneous fat mass (kg)'] = readUInt16LE(29) / 10.0;

      // 31~32 Subcutaneous fat rate (0.1%)
      results['Subcutaneous fat %'] = readUInt16LE(31) / 10.0;

      // 33 subcutaneous fat rate std0 (0.1)
      results['Subcut fat % std0'] = readUInt8(33) / 10.0;

      // 34~35 subcut fat std1
      results['Subcut fat % std1'] = readUInt16LE(34) / 10.0;

      // 36 body score (uint8)
      results['Body score'] = readUInt8(36);

      // 37 body type (uint8)
      results['Body type'] = readUInt8(37);

      // 38 bone mass (0.1kg)
      results['Bone mass (kg)'] = readUInt8(38) / 10.0;

      // 39~40 bone mass stds (0.1)
      results['Bone mass std0'] = readUInt8(39) / 10.0;
      results['Bone mass std1'] = readUInt8(40) / 10.0;

      // 41~42 ideal weight (0.1kg)
      results['Ideal weight (kg)'] = readUInt16LE(41) / 10.0;

      // 43~44 Moisture rate (0.1%)
      results['Moisture %'] = readUInt16LE(43) / 10.0;

      // 45~46 Moisture content std0
      results['Moisture std0'] = readUInt16LE(45) / 10.0;

      // 47~48 Moisture rate std1
      results['Moisture std1'] = readUInt16LE(47) / 10.0;

      // 49 Visceral fat level (uint8)
      results['Visceral fat level'] = readUInt8(49);

      // 52~53 skeletal muscle mass (0.1kg)
      results['Skeletal muscle mass (kg)'] = readUInt16LE(52) / 10.0;

      // 57~58 protein rate (0.1%)
      results['Protein %'] = readUInt16LE(57) / 10.0;

      // 61~62 muscle rate (0.1%)
      results['Muscle %'] = readUInt16LE(61) / 10.0;

      // 63~64 muscle mass (0.1kg)
      results['Muscle mass (kg)'] = readUInt16LE(63) / 10.0;

      // 65~66 muscle mass std0
      results['Muscle mass std0'] = readUInt16LE(65) / 10.0;

      // 67~68 muscle mass std1
      results['Muscle mass std1'] = readUInt16LE(67) / 10.0;

      // 71~72 example exercise Kcal etc (kept for completeness)
      // 77~78 subcutaneous fat mass (end) -> final check-digit location is often later
      // many other fields exist; protocol gives up to ~79 bytes in the first package.

      // Convert some commonly used results to friendly format if present:
      // already filled above: Fat mass, Fat %, BMI, BMR, Visceral fat, Bone mass, Muscle mass, Protein %
    } catch (e) {
      _addLog('Error parsing algorithm response: $e');
    }

    // store and show
    setState(() {
      _algorithmResults = results;
    });

    _addLog('Algorithm results parsed: $_algorithmResults');
  }

  // ---------- UI Utilities ----------
  void _addLog(String message) {
    setState(() {
      final t = DateTime.now().toString().substring(11, 19);
      _log += '$t: $message\n';
    });
    print(message);
  }

  void _clearLog() {
    setState(() => _log = '');
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

  // ---------- Build UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('BMH05108 Arms Monitor'),
        backgroundColor: Colors.blue[700],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(12.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Connection
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
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
                        SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButton<DeviceInfo>(
                                hint: Text('Select Device'),
                                value: _selectedDevice,
                                isExpanded: true,
                                items: _availableDevices.map((device) {
                                  return DropdownMenuItem(
                                    value: device,
                                    child: Text(
                                      '${device.deviceName} (${device.manufacturerName})',
                                    ),
                                  );
                                }).toList(),
                                onChanged: (value) =>
                                    setState(() => _selectedDevice = value),
                              ),
                            ),
                            SizedBox(width: 8),
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
                            SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: _isConnected
                                  ? _disconnectDevice
                                  : null,
                              child: Text('Disconnect'),
                            ),
                            SizedBox(width: 8),
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
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
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
                                color: Colors.grey[700],
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // Controls
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
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
                        SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ElevatedButton(
                              onPressed: _isConnected
                                  ? _getDeviceVersion
                                  : null,
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
                        SizedBox(height: 6),
                        Text(
                          'Notes: stop mode (B0 mode = 0x00) clears impedance history. Use weight calibration (A0 mode 0x03) only if you use load cell.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Impedance / Data
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
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
                        SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Status: $_impedanceStatus',
                              style: TextStyle(color: Colors.grey[600]),
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
                        SizedBox(height: 10),
                        Text(
                          'Instructions:',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
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
                          childAspectRatio: 2.6,
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
                ),

                // Algorithm results
                if (_algorithmResults.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Body Composition Results',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 8),
                          ..._algorithmResults.entries.map((e) {
                            final value = e.value is double
                                ? (e.value as double).toStringAsFixed(1)
                                : e.value.toString();
                            return Padding(
                              padding: EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '${e.key}: $value',
                                style: TextStyle(fontSize: 14),
                              ),
                            );
                          }).toList(),
                        ],
                      ),
                    ),
                  ),

                // Logs
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
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
                        SizedBox(height: 8),
                        Container(
                          constraints: BoxConstraints(
                            minHeight: 120,
                            maxHeight: 300,
                          ),
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
                      ],
                    ),
                  ),
                ),

                SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
