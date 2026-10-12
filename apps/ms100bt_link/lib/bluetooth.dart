// Platform byte pipe to the pedal. Native side: Android (Kotlin, Bluetooth SPP socket),
// macOS (Swift, IOBluetooth RFCOMM), iOS (ExternalAccessory, diagnostics only for now).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:zoom_core/zoom_core.dart';

class PairedDevice {
  const PairedDevice(this.address, this.name);
  final String address;
  final String name;
  bool get looksLikePedal => name.toUpperCase().contains('MS-100') || name.toUpperCase().contains('ZOOM');
}

class BluetoothBridge implements PedalTransport {
  BluetoothBridge._();

  static const _method = MethodChannel('ms100bt/bluetooth');
  static const _events = EventChannel('ms100bt/bluetooth/rx');
  static final Stream<List<int>> _rx =
      _events.receiveBroadcastStream().map((e) => List<int>.from(e as List<int>)).asBroadcastStream();

  static Future<List<PairedDevice>> pairedDevices() async {
    final list = await _method.invokeListMethod<Map<dynamic, dynamic>>('pairedDevices') ?? const [];
    return [for (final d in list) PairedDevice(d['address'] as String, d['name'] as String? ?? '?')];
  }

  /// Opens the pedal's Serial Port (SDP 0x1101) channel.
  static Future<BluetoothBridge> connect(String address) async {
    final bridge = BluetoothBridge._();
    bridge._sub = _rx.listen(bridge._incoming.add); // listen before connecting: nothing is lost
    await _method.invokeMethod<void>('connect', {'address': address});
    return bridge;
  }

  /// Platform notes (iOS: connected MFi accessories and their protocol names).
  static Future<Map<String, Object?>> diagnostics() async =>
      (await _method.invokeMapMethod<String, Object?>('diagnostics')) ?? const {};

  final _incoming = StreamController<List<int>>.broadcast();
  StreamSubscription<List<int>>? _sub;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    Allowlist.validate(bytes); // transport-level gate, as in every transport
    await _method.invokeMethod<void>('write', Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _incoming.close();
    await _method.invokeMethod<void>('disconnect');
  }
}
