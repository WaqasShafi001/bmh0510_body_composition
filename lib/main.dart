import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_serial_communication/flutter_serial_communication.dart';
import 'package:flutter_serial_communication/models/device_info.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BMH05108 Body Composition',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const BodyCompositionScreen(),
    );
  }
}

class BodyCompositionScreen extends StatefulWidget {
  const BodyCompositionScreen({super.key});

  @override
  State<BodyCompositionScreen> createState() => _BodyCompositionScreenState();
}

class _BodyCompositionScreenState extends State<BodyCompositionScreen> {
  final FlutterSerialCommunication _serial = FlutterSerialCommunication();
  List<DeviceInfo> _devices = [];
  DeviceInfo? _selected;
  bool _connected = false;
  String _log = "";

  final List<int> _recvBuffer = [];
  int _expectedLength = -1;

  StreamSubscription? _serialSubscription;

  // user input
  int _age = 30;
  double _weightKg = 70;
  int _heightFeet = 5;
  int _heightInch = 7;
  int _sex = 1; // 1=male, 0=female

  double? _impedance;
  Map<String, dynamic> _results = {};

  int _impedanceRetries = 0;
  int _currentMode = 0x03; // default TwoArms
  bool _autoSwitchTried = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _serialSubscription?.cancel();
    _serial.disconnect();
    super.dispose();
  }

  Future<void> _scan() async {
    final d = await _serial.getAvailableDevices();
    setState(() => _devices = d);
    _addLog("Found ${d.length} devices");
  }

  Future<void> _connect() async {
    if (_selected == null) return;
    bool ok = await _serial.connect(_selected!, 38400);
    if (ok) {
      setState(() => _connected = true);
      _setupListeners();
      _addLog("Connected to ${_selected!.deviceName}");
      await Future.delayed(const Duration(milliseconds: 200));
      _send([0x55, 0x05, 0xE0, 0x00, 0xC6], "Get Version");
    } else {
      _addLog("Failed to connect");
    }
  }

  void _setupListeners() {
    // FIXED: EventChannel requires receiveBroadcastStream() before listen()
    _serialSubscription = _serial
        .getSerialMessageListener()
        .receiveBroadcastStream()
        .listen(
          (data) {
            if (data is Uint8List) {
              _handle(data);
            } else if (data is List<int>) {
              _handle(Uint8List.fromList(data));
            } else {
              _addLog("Unexpected data type: ${data.runtimeType}");
            }
          },
          onError: (error) {
            _addLog("Serial error: $error");
          },
          cancelOnError: false,
        );
  }

  void _send(List<int> cmd, String desc) async {
    final sent = await _serial.write(Uint8List.fromList(cmd));
    if (sent) {
      _addLog(
        "Sent $desc: ${cmd.map((e) => e.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ')}",
      );
    } else {
      _addLog("Failed to send $desc");
    }
  }

  void _addLog(String m) {
    setState(() {
      _log += "$m\n";
      // Keep log manageable
      final lines = _log.split('\n');
      if (lines.length > 100) {
        _log = lines.sublist(lines.length - 100).join('\n');
      }
    });
    print(m);
  }

  void _handle(Uint8List data) {
    _addLog(
      "Received ${data.length} bytes: ${data.map((e) => e.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ')}",
    );

    // Append new data
    _recvBuffer.addAll(data);

    // Process all complete packets in buffer
    while (_recvBuffer.isNotEmpty) {
      // Look for frame header
      if (_recvBuffer[0] != 0xAA) {
        _addLog("Invalid frame header: 0x${_recvBuffer[0].toRadixString(16)}");
        _recvBuffer.removeAt(0);
        continue;
      }

      // Need at least 2 bytes to read length
      if (_recvBuffer.length < 2) break;

      final frameLength = _recvBuffer[1];

      // Wait for complete frame
      if (_recvBuffer.length < frameLength) break;

      // Extract complete packet
      final packet = Uint8List.fromList(_recvBuffer.sublist(0, frameLength));

      // Verify checksum
      if (!_verifyChecksum(packet)) {
        _addLog("Checksum failed for packet");
        _recvBuffer.removeRange(0, frameLength);
        continue;
      }

      // Remove processed bytes
      _recvBuffer.removeRange(0, frameLength);

      // Process packet
      final cmd = packet[2];
      switch (cmd) {
        case 0xE0:
          _parseVersion(packet);
          break;
        case 0xB0:
          _parseModeSwitch(packet);
          break;
        case 0xB1:
          _parseImpedance(packet);
          break;
        case 0xD2:
          _parseD2(packet);
          break;
        default:
          _addLog("Unknown command: 0x${cmd.toRadixString(16)}");
      }
    }
  }

  bool _verifyChecksum(Uint8List packet) {
    if (packet.isEmpty) return false;
    int sum = 0;
    for (int i = 0; i < packet.length - 1; i++) {
      sum = (sum + packet[i]) & 0xFF;
    }
    int expectedChecksum = ((~sum) + 1) & 0xFF;
    return packet[packet.length - 1] == expectedChecksum;
  }

  void _parseVersion(Uint8List d) {
    if (d.length < 7) {
      _addLog("Version packet too short: ${d.length} bytes");
      return;
    }

    final appType = d[3];
    final versionLow = d[4];
    final versionHigh = d[5];

    String appName;
    switch (appType) {
      case 0x00:
        appName = "Master";
        break;
      case 0x01:
        appName = "BIA";
        break;
      case 0x02:
        appName = "Weight";
        break;
      default:
        appName = "Unknown";
    }

    _addLog("Device version: $appName v$versionHigh.$versionLow");
  }

  void _parseModeSwitch(Uint8List d) {
    if (d.length < 5) {
      _addLog("Mode switch response too short");
      return;
    }

    final result = d[3];
    switch (result) {
      case 0x00:
        _addLog("Mode switch OK (mode=0x${_currentMode.toRadixString(16)})");
        // Increased delay before querying impedance
        Future.delayed(const Duration(milliseconds: 1000), () {
          _impedanceRetries = 0;
          _queryImpedance();
        });
        break;
      case 0x01:
        _addLog("Mode switch failed: Working mode error");
        break;
      case 0x02:
        _addLog("Mode switch failed: Frequency error");
        break;
      default:
        _addLog("Mode switch failed: Unknown error $result");
    }
  }

  void _queryImpedance() {
    _send([0x55, 0x05, 0xB1, 0x51, 0xA4], "Query 50kHz impedance");
  }

  void _parseImpedance(Uint8List d) {
    if (d.length < 13) {
      _addLog("Impedance packet too short: ${d.length} bytes");
      return;
    }

    final frequency = d[3];
    final state = d[4];

    if (state != 0x03) {
      String stateStr;
      switch (state) {
        case 0x01:
          stateStr = "Checking electrode";
          break;
        case 0x02:
          stateStr = "Measuring";
          break;
        case 0x04:
          stateStr = "Error - abnormal data";
          break;
        case 0x05:
          stateStr = "Error - repeated abnormalities";
          break;
        case 0x06:
          stateStr = "User exited";
          break;
        default:
          stateStr = "Unknown ($state)";
      }

      _addLog("Impedance state: $stateStr");

      // Automatic retry logic
      if (state == 0x01 && _impedanceRetries < 3) {
        _impedanceRetries++;
        _addLog("Retrying impedance (#$_impedanceRetries) in 1s...");
        Future.delayed(const Duration(seconds: 1), _queryImpedance);
        return;
      }

      // After retries, try switching to other mode
      if (state == 0x01 && !_autoSwitchTried) {
        _autoSwitchTried = true;
        _addLog("Switching to FourElectrode mode (0x02)...");
        _switchMode(0x02);
        return;
      }

      return;
    }

    // Parsing impedance value (bytes 8–11)
    final imp = d[8] | (d[9] << 8) | (d[10] << 16) | (d[11] << 24);
    if (imp > 0 && imp < 1200) {
      setState(() => _impedance = imp.toDouble());
      _addLog("Two-arms impedance (50kHz): $_impedance Ω");
    } else {
      _addLog("Invalid impedance value: $imp Ω");
    }
  }

  void _switchMode(int mode) {
    _currentMode = mode;
    _impedanceRetries = 0;
    int sum = (0x55 + 0x06 + 0xB0 + mode + 0x05) & 0xFF;
    int chk = ((~sum) + 1) & 0xFF;
    _send([
      0x55,
      0x06,
      0xB0,
      mode,
      0x05,
      chk,
    ], "Switch to mode=0x${mode.toRadixString(16)} 50kHz");
  }

  // void _startImpedance() {
  //   _addLog("==== Starting impedance measurement ====");
  //   // Switch to TwoArms (0x03) mode, 50kHz (0x05)
  //   // _send([0x55, 0x06, 0xB0, 0x03, 0x05, 0xED], "Switch to TwoArms 50kHz mode");
  //   _send([
  //     0x55,
  //     0x06,
  //     0xB0,
  //     0x02,
  //     0x05,
  //     0xEE,
  //   ], "Switch to FourElectrode 50kHz mode");
  // }
  void _startImpedance() {
    _addLog("==== Starting impedance measurement ====");
    _autoSwitchTried = false;
    _switchMode(0x03); // start with TwoArms
  }

  Future<void> _sendSelfTest() async {
    final List<Map<String, List<int>>> tests = [
      {
        "Master self-test": [0x55, 0x05, 0xB3, 0x00, 0xF3],
      },
      {
        "BIA self-test": [0x55, 0x05, 0xB3, 0x01, 0xF2],
      },
      {
        "Weight self-test": [0x55, 0x05, 0xB3, 0x02, 0xF1],
      },
    ];

    bool gotResponse = false;

    for (final test in tests) {
      final desc = test.keys.first;
      final cmd = test.values.first;

      _addLog("Sending $desc...");
      final sent = await _serial.write(Uint8List.fromList(cmd));
      if (sent) {
        _addLog(
          "Sent $desc: ${cmd.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ').toUpperCase()}",
        );
      } else {
        _addLog("Failed to send $desc");
      }

      // Wait up to 1 second for any response
      final completer = Completer<void>();
      late StreamSubscription sub;
      sub = _serial.getSerialMessageListener().receiveBroadcastStream().listen((
        data,
      ) {
        if (data is Uint8List && data.isNotEmpty && data[2] == 0xB3) {
          gotResponse = true;
          _addLog(
            "Self-test response received: ${data.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ').toUpperCase()}",
          );
          sub.cancel();
          completer.complete();
        }
      });

      await Future.any([
        completer.future,
        Future.delayed(const Duration(seconds: 2)),
      ]);
      await sub.cancel();
    }

    if (!gotResponse) {
      _addLog(
        "⚠️ No B3 responses detected. This firmware (Master v1.5) likely does not support self-test command.",
      );
    } else {
      _addLog("✅ Self-test command supported and responded successfully.");
    }
  }

  void _calculate() {
    if (_impedance == null) {
      _addLog("No impedance measurement yet. Please measure first.");
      return;
    }

    int heightCm = (_heightFeet * 30.48 + _heightInch * 2.54).round();
    if (heightCm < 90 || heightCm > 220) {
      _addLog("Height out of range: $heightCm cm (valid: 90-220)");
      return;
    }

    if (_age < 6 || _age > 99) {
      _addLog("Age out of range: $_age (valid: 6-99)");
      return;
    }

    int weight10 = (_weightKg * 10).round();
    if (weight10 < 100 || weight10 > 2000) {
      _addLog("Weight out of range: $_weightKg kg (valid: 10-200)");
      return;
    }

    int imp = _impedance!.round();
    if (imp < 10 || imp > 1200) {
      _addLog("Impedance out of range: $imp Ω (valid: 10-1200)");
      return;
    }

    // FIXED: Correct checksum calculation
    final payload = [
      0x55, // Frame header
      0x0C, // Frame length
      0xD2, // Command (TwoArms algorithm)
      _sex, // Gender: 0=female, 1=male
      0x00, // User type: 0=normal, 1=athlete
      heightCm, // Height in cm
      _age, // Age in years
      weight10 & 0xFF, // Weight low byte (0.1kg units)
      (weight10 >> 8) & 0xFF, // Weight high byte
      imp & 0xFF, // Impedance low byte (1Ω units)
      (imp >> 8) & 0xFF, // Impedance high byte
    ];

    // Calculate checksum: ~(sum of all bytes) + 1
    int sum = 0;
    for (int b in payload) {
      sum = (sum + b) & 0xFF;
    }
    int checksum = ((~sum) + 1) & 0xFF;
    payload.add(checksum);

    _addLog(
      "Calculating with: H=$heightCm cm, A=$_age y, W=$_weightKg kg, Z=$imp Ω",
    );
    _send(payload, "D2 Algorithm input");
  }

  void _parseD2(Uint8List d) {
    if (d.length < 86) {
      _addLog("D2 packet incomplete: ${d.length} bytes (expected 86)");
      return;
    }

    final packetNum = d[3];
    final errorType = d[4];

    if (errorType != 0x00) {
      String errorMsg;
      switch (errorType) {
        case 0x01:
          errorMsg = "Wrong age";
          break;
        case 0x02:
          errorMsg = "Wrong height";
          break;
        case 0x03:
          errorMsg = "Wrong weight";
          break;
        case 0x04:
          errorMsg = "Wrong gender";
          break;
        case 0x05:
          errorMsg = "User type error";
          break;
        case 0x07:
          errorMsg = "Hand impedance error";
          break;
        default:
          errorMsg = "Unknown error ($errorType)";
      }
      _addLog("D2 calculation error: $errorMsg");
      return;
    }

    _addLog(
      "Parsing D2 response (packet ${packetNum & 0x0F}/${(packetNum >> 4)})",
    );

    Map<String, dynamic> r = {};

    // Helper functions for little-endian parsing
    int u16(int i) => d[i] | (d[i + 1] << 8);
    int u8(int i) => d[i];

    try {
      // FIXED: Correct byte indices according to protocol document page 24-26
      r["Fat mass (kg)"] = u16(5) / 10.0; // Bytes 5-6
      r["Fat %"] = u16(7) / 10.0; // Bytes 7-8
      r["Fat % (min)"] = u8(9) / 10.0; // Byte 9
      r["Fat % (standard 1)"] = u16(10) / 10.0; // Bytes 10-11
      r["Fat % (standard 2)"] = u16(12) / 10.0; // Bytes 12-13
      r["Fat % (standard 3)"] = u16(14) / 10.0; // Bytes 14-15
      r["BMI"] = u16(16) / 10.0; // Bytes 16-17
      r["BMI (min)"] = u8(18) / 10.0; // Byte 18
      r["BMI (max 1)"] = u8(19) / 10.0; // Byte 19
      r["BMI (max 2)"] = u16(20) / 10.0; // Bytes 20-21
      r["BMR (kcal)"] = u16(22); // Bytes 22-23
      r["BMR min (kcal)"] = u16(24); // Bytes 24-25
      r["Physical age"] = u8(26); // Byte 26
      r["Lean mass (kg)"] = u16(27) / 10.0; // Bytes 27-28
      r["Subcutaneous fat mass (kg)"] = u16(29) / 10.0; // Bytes 29-30
      r["Subcutaneous fat %"] = u16(31) / 10.0; // Bytes 31-32
      r["Subcutaneous fat % (min)"] = u8(33) / 10.0; // Byte 33
      r["Subcutaneous fat % (max)"] = u16(34) / 10.0; // Bytes 34-35
      r["Body score"] = u8(36); // Byte 36
      r["Body type"] = _getBodyTypeName(u8(37)); // Byte 37
      r["Bone mass (kg)"] = u8(38) / 10.0; // Byte 38
      r["Bone mass min (kg)"] = u8(39) / 10.0; // Byte 39
      r["Bone mass max (kg)"] = u8(40) / 10.0; // Byte 40
      r["Ideal weight (kg)"] = u16(41) / 10.0; // Bytes 41-42
      r["Moisture %"] = u16(43) / 10.0; // Bytes 43-44
      r["Moisture % (min)"] = u16(45) / 10.0; // Bytes 45-46
      r["Moisture % (max)"] = u16(47) / 10.0; // Bytes 47-48
      r["Visceral fat level"] = u8(49); // Byte 49
      r["Visceral fat (min)"] = u8(50); // Byte 50
      r["Visceral fat (max)"] = u8(51); // Byte 51
      r["Skeletal muscle (kg)"] = u16(52) / 10.0; // Bytes 52-53
      r["Skeletal muscle min (kg)"] = u8(54) / 10.0; // Byte 54
      r["Skeletal muscle max (kg)"] = u16(55) / 10.0; // Bytes 55-56
      r["Protein %"] = u16(57) / 10.0; // Bytes 57-58
      r["Protein % (min)"] = u8(59) / 10.0; // Byte 59
      r["Protein % (max)"] = u8(60) / 10.0; // Byte 60
      r["Muscle %"] = u16(61) / 10.0; // Bytes 61-62
      r["Muscle mass (kg)"] = u16(63) / 10.0; // Bytes 63-64
      r["Muscle mass min (kg)"] = u16(65) / 10.0; // Bytes 65-66
      r["Muscle mass max (kg)"] = u16(67) / 10.0; // Bytes 67-68

      // Exercise expenditure (kCal/30min)
      r["Walk"] = u16(69);
      r["Golf"] = u16(71);
      r["Croquet"] = u16(73);
      r["Tennis/Cycling/Basketball"] = u16(75);
      r["Squash/Taekwondo/Fencing"] = u16(77);
      r["Climb mountains"] = u16(79);
      r["Swimming/Aerobics/Jogging"] = u16(81);
      r["Badminton/Table tennis"] = u16(83);
    } catch (e) {
      _addLog("Parse error: $e");
    }

    setState(() => _results = r);
    _addLog("Successfully parsed ${r.length} body composition parameters");
  }

  String _getBodyTypeName(int type) {
    switch (type) {
      case 0x01:
        return "Thin";
      case 0x02:
        return "Thin muscular";
      case 0x03:
        return "Muscular";
      case 0x04:
        return "Bloated obesity";
      case 0x05:
        return "Fat muscular";
      case 0x06:
        return "Muscular fat";
      case 0x07:
        return "Lack exercise";
      case 0x08:
        return "Standard";
      case 0x09:
        return "Standard muscle";
      default:
        return "Unknown ($type)";
    }
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(title: const Text("BMH05108 Body Composition")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Device connection section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Device Connection",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<DeviceInfo>(
                            isExpanded: true,
                            hint: const Text("Select Device"),
                            value: _selected,
                            items: _devices
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e,
                                    child: Text(
                                      "${e.deviceName} (${e.manufacturerName})",
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(() => _selected = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _scan,
                          child: const Text("Scan"),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _connected ? null : _connect,
                          child: Text(_connected ? "Connected" : "Connect"),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // User information section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "User Information",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              labelText: "Age (years)",
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                            controller: TextEditingController(
                              text: _age.toString(),
                            ),
                            onChanged: (v) => _age = int.tryParse(v) ?? 30,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              labelText: "Weight (kg)",
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                            controller: TextEditingController(
                              text: _weightKg.toString(),
                            ),
                            onChanged: (v) =>
                                _weightKg = double.tryParse(v) ?? 70,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              labelText: "Height (feet)",
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                            controller: TextEditingController(
                              text: _heightFeet.toString(),
                            ),
                            onChanged: (v) =>
                                _heightFeet = int.tryParse(v) ?? 5,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              labelText: "Height (inches)",
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                            controller: TextEditingController(
                              text: _heightInch.toString(),
                            ),
                            onChanged: (v) =>
                                _heightInch = int.tryParse(v) ?? 7,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text("Sex: "),
                        Radio(
                          value: 1,
                          groupValue: _sex,
                          onChanged: (v) => setState(() => _sex = v as int),
                        ),
                        const Text("Male"),
                        Radio(
                          value: 0,
                          groupValue: _sex,
                          onChanged: (v) => setState(() => _sex = v as int),
                        ),
                        const Text("Female"),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Measurement section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Measurement",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _connected ? _sendSelfTest : null,
                      icon: const Icon(Icons.settings),
                      label: const Text("Run Self-Test"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _connected ? _startImpedance : null,
                      icon: const Icon(Icons.electric_bolt),
                      label: const Text("Measure Impedance"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                    if (_impedance != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green[50],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Colors.green),
                            const SizedBox(width: 8),
                            Text(
                              "Impedance: ${_impedance!.toStringAsFixed(1)} Ω",
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: (_impedance != null) ? _calculate : null,
                      icon: const Icon(Icons.calculate),
                      label: const Text("Calculate Body Composition"),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Results section
            if (_results.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Body Composition Results",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Divider(),
                      // 2 columns grid layout
                      GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        childAspectRatio:
                            9.8, // Adjust spacing (higher = flatter)
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 10,
                        children: _results.entries.map((e) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey[50],
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  e.key,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.black87,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  e.value is double
                                      ? (e.value as double).toStringAsFixed(1)
                                      : e.value.toString(),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blueAccent,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),

            // Card(
            //   child: Padding(
            //     padding: const EdgeInsets.all(12),
            //     child: Column(
            //       crossAxisAlignment: CrossAxisAlignment.start,
            //       children: [
            //         const Text(
            //           "Body Composition Results",
            //           style: TextStyle(
            //             fontSize: 18,
            //             fontWeight: FontWeight.bold,
            //           ),
            //         ),
            //         const Divider(),
            //         ..._results.entries.map(
            //           (e) => Padding(
            //             padding: const EdgeInsets.symmetric(vertical: 4),
            //             child: Row(
            //               mainAxisAlignment: MainAxisAlignment.spaceBetween,
            //               children: [
            //                 Expanded(
            //                   child: Text(
            //                     e.key,
            //                     style: const TextStyle(fontSize: 14),
            //                   ),
            //                 ),
            //                 Text(
            //                   e.value is double
            //                       ? (e.value as double).toStringAsFixed(1)
            //                       : e.value.toString(),
            //                   style: const TextStyle(
            //                     fontSize: 14,
            //                     fontWeight: FontWeight.bold,
            //                   ),
            //                 ),
            //               ],
            //             ),
            //           ),
            //         ),
            //       ],
            //     ),
            //   ),
            // ),
            const SizedBox(height: 12),

            // Log section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Communication Log",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _log = ""),
                          child: const Text("Clear"),
                        ),
                      ],
                    ),
                    const Divider(),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: SingleChildScrollView(
                        child: Text(
                          _log.isEmpty ? "No logs yet" : _log,
                          style: const TextStyle(
                            fontFamily: "monospace",
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
