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

  List<int> _recvBuffer = [];
  int _expectedLength = -1;

  String _deviceVersion = '';

  StreamSubscription? _msgSub;
  StreamSubscription? _connSub;

  // user input
  int _age = 30;
  double _weightKg = 70;
  int _heightFeet = 5;
  int _heightInch = 7;
  int _sex = 1; // 1=male, 0=female

  double? _impedance;
  Map<String, dynamic> _results = {};

  @override
  void initState() {
    super.initState();
    _scan();
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
    }
  }

  void _setupListeners() {
    _msgSub = _serial
        .getSerialMessageListener()
        .receiveBroadcastStream()
        .listen((data) {
          if (data is List<int>) _handle(Uint8List.fromList(data));
        });

    _connSub = _serial
        .getDeviceConnectionListener()
        .receiveBroadcastStream()
        .listen((s) {
          if (s == false) setState(() => _connected = false);
        });
  }

  void _send(List<int> cmd, String desc) async {
    final sent = await _serial.write(Uint8List.fromList(cmd));
    if (sent)
      _addLog(
        "Sent $desc: ${cmd.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}",
      );
  }

  void _addLog(String m) {
    setState(() => _log += "$m\n");
    print(m);
  }

  // void _handle(Uint8List data) {
  //   _addLog(
  //     "Raw: ${data.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}",
  //   );

  //   if (data.isEmpty || data[0] != 0xAA) return;
  //   final cmd = data[2];

  //   switch (cmd) {
  //     case 0xB1:
  //       if (data.length >= 12) _parseImpedance(data);
  //       break;
  //     case 0xD2:
  //       _parseD2(data); // inside we’ll check lengths carefully
  //       break;
  //     case 0xE0:
  //       // version info
  //       break;
  //   }
  // }

  void _handle(Uint8List data) {
    // Append new data
    _recvBuffer.addAll(data);

    // If we don’t yet know the frame length, check
    if (_expectedLength == -1 && _recvBuffer.length >= 2) {
      _expectedLength = _recvBuffer[1]; // 2nd byte is length
    }

    // Do we have enough bytes for a full frame?
    if (_expectedLength != -1 && _recvBuffer.length >= _expectedLength) {
      // Extract the complete packet
      final fullPacket = Uint8List.fromList(
        _recvBuffer.sublist(0, _expectedLength),
      );

      // Remove processed bytes from buffer
      _recvBuffer = _recvBuffer.sublist(_expectedLength);

      // Reset expected length for next packet
      _expectedLength = -1;

      // Process packet
      final cmd = fullPacket[2];
      if (cmd == 0xD2) {
        _parseD2(fullPacket);
      } else if (cmd == 0xB1) {
        _parseImpedance(fullPacket);
      } else if (cmd == 0xE0) {
        _parseVersion(fullPacket);
      }
    }
  }

  void _parseVersion(Uint8List d) {
    if (d.length < 6) {
      _addLog("Version packet too short: ${d.length} bytes");
      return;
    }

    final appType = d[3];
    final version = (d[5] << 8) | d[4]; // little-endian
    final major = (version >> 8) & 0xFF;
    final minor = version & 0xFF;

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

    final versionStr = "$appName v$major.$minor";

    setState(() {
      _deviceVersion = versionStr;
    });

    _addLog("Device version: $versionStr");
  }

  void _parseImpedance(Uint8List d) {
    final state = d[4];
    if (state != 0x03) {
      _addLog("Impedance state not ready (state=$state)");
      return;
    }
    final imp = (d[11] << 24) | (d[10] << 16) | (d[9] << 8) | d[8];
    if (imp > 0) {
      setState(() => _impedance = imp.toDouble());
      _addLog("Two-arms impedance: $_impedance Ω");
    }
  }

  void _startImpedance() {
    // Switch to 2-arms, 50kHz
    _send([0x55, 0x06, 0xB0, 0x03, 0x05, 0xED], "Switch to TwoArms 50kHz mode");
    _addLog("Button clicked =============");

    Future.delayed(const Duration(seconds: 3), () {
      _addLog("Now asking the chip for impedence =============");

      _send([0x55, 0x05, 0xB1, 0x51, 0xA4], "Query TwoArms impedance");
    });
  }

  void _calculate() {
    if (_impedance == null) {
      _addLog("No impedance yet");
      return;
    }
    int heightCm = (_heightFeet * 30.48 + _heightInch * 2.54).round();
    int weight10 = (_weightKg * 10).round();
    int imp = _impedance!.round();

    final payload = [
      0x55,
      0x0C,
      0xD2,
      _sex, // gender
      0x00, // user type normal
      heightCm,
      _age,
      weight10 & 0xFF,
      (weight10 >> 8) & 0xFF,
      imp & 0xFF,
      (imp >> 8) & 0xFF,
    ];
    // checksum
    int sum = payload.reduce((a, b) => (a + b) & 0xFF);
    int lrc = ((~sum + 1) & 0xFF);
    payload.add(lrc);
    _send(payload, "D2 Algorithm input");
  }

  // void _parseD2(Uint8List d) {
  //   if (d.length < 10) {
  //     _addLog("D2 packet too short: ${d.length} bytes");
  //     return;
  //   }
  //   Map<String, dynamic> r = {};
  //   int u16(int i) => (i + 1 < d.length) ? (d[i] | (d[i + 1] << 8)) : 0;
  //   int u8(int i) => (i < d.length) ? d[i] : 0;

  //   if (d.length >= 9) r["Fat mass (kg)"] = u16(5) / 10.0;
  //   if (d.length >= 11) r["Fat %"] = u16(7) / 10.0;
  //   if (d.length >= 18) r["BMI"] = u16(16) / 10.0;
  //   if (d.length >= 24) r["BMR"] = u16(22);
  //   if (d.length >= 29) r["Lean mass (kg)"] = u16(27) / 10.0;
  //   if (d.length >= 39) r["Bone mass (kg)"] = u8(38) / 10.0;
  //   if (d.length >= 45) r["Moisture %"] = u16(43) / 10.0;
  //   if (d.length >= 50) r["Visceral fat"] = u8(49);
  //   if (d.length >= 54) r["Skeletal muscle (kg)"] = u16(52) / 10.0;
  //   if (d.length >= 59) r["Protein %"] = u16(57) / 10.0;

  //   setState(() => _results = r);
  //   _addLog("Parsed D2 results (partial): $r");
  // }

  void _parseD2(Uint8List d) {
    if (d.length < 10) {
      _addLog("D2 too short: ${d.length} bytes");
      return;
    }

    Map<String, dynamic> r = {};

    int u16(int i) => (i + 1 < d.length) ? (d[i] | (d[i + 1] << 8)) : 0;
    int u8(int i) => (i < d.length) ? d[i] : 0;

    try {
      if (d.length >= 9) r["Fat mass (kg)"] = u16(5) / 10.0;
      if (d.length >= 11) r["Fat %"] = u16(7) / 10.0;
      if (d.length >= 18) r["BMI"] = u16(16) / 10.0;
      if (d.length >= 24) r["BMR (kcal)"] = u16(22);
      if (d.length >= 29) r["Lean mass (kg)"] = u16(27) / 10.0;
      if (d.length >= 39) r["Bone mass (kg)"] = u8(38) / 10.0;
      if (d.length >= 45) r["Moisture %"] = u16(43) / 10.0;
      if (d.length >= 50) r["Visceral fat level"] = u8(49);
      if (d.length >= 54) r["Skeletal muscle (kg)"] = u16(52) / 10.0;
      if (d.length >= 59) r["Protein %"] = u16(57) / 10.0;
      if (d.length >= 63) r["Muscle %"] = u16(61) / 10.0;
      if (d.length >= 65) r["Muscle mass (kg)"] = u16(63) / 10.0;
    } catch (e) {
      _addLog("Parse error: $e");
    }

    setState(() => _results = r);
    _addLog("Parsed D2 results: $r");
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
            Row(
              children: [
                Expanded(
                  child: DropdownButton<DeviceInfo>(
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
                ElevatedButton(onPressed: _scan, child: const Text("Scan")),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? null : _connect,
                  child: const Text("Connect"),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text("User Info"),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(labelText: "Age"),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _age = int.tryParse(v) ?? 30,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(labelText: "Weight (kg)"),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _weightKg = double.tryParse(v) ?? 70,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(labelText: "Height (ft)"),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _heightFeet = int.tryParse(v) ?? 5,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(labelText: "Height (in)"),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _heightInch = int.tryParse(v) ?? 7,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const Text("Sex:"),
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
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _connected ? _startImpedance : null,
              child: const Text("Measure Impedance"),
            ),
            if (_impedance != null)
              Text("Measured Impedance: ${_impedance!.toStringAsFixed(1)} Ω"),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: (_impedance != null) ? _calculate : null,
              child: const Text("Calculate Body Composition"),
            ),
            const SizedBox(height: 20),
            if (_results.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _results.entries
                    .map((e) => Text("${e.key}: ${e.value}"))
                    .toList(),
              ),
            const SizedBox(height: 20),
            Text("Log:"),
            Text(_log, style: const TextStyle(fontFamily: "monospace")),
          ],
        ),
      ),
    );
  }
}
