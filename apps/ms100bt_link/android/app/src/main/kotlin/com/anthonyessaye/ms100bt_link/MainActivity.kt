package com.anthonyessaye.ms100bt_link

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID

/**
 * Byte pipe to the Zoom MS-100BT over classic Bluetooth SPP (RFCOMM), for the shared Dart core.
 * The Dart side validates every outbound frame against the allowlist before it reaches write().
 */
class MainActivity : FlutterActivity() {
    private val spp: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val main = Handler(Looper.getMainLooper())
    private var socket: BluetoothSocket? = null
    private var reader: Thread? = null
    private var sink: EventChannel.EventSink? = null
    private var pendingPermission: (() -> Unit)? = null

    private val adapter: BluetoothAdapter?
        get() = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "ms100bt/bluetooth").setMethodCallHandler { call, result -> handle(call, result) }
        EventChannel(messenger, "ms100bt/bluetooth/rx").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
            override fun onCancel(arguments: Any?) { sink = null }
        })
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pairedDevices" -> withPermission(result) { pairedDevices(result) }
            "connect" -> withPermission(result) { connect(call.argument<String>("address") ?: "", result) }
            "write" -> write(call.arguments as ByteArray, result)
            "disconnect" -> { close(); result.success(null) }
            "diagnostics" -> result.success(mapOf("platform" to "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})",
                                                  "bluetooth" to if (adapter?.isEnabled == true) "on" else "off"))
            else -> result.notImplemented()
        }
    }

    // Android 12+ needs BLUETOOTH_CONNECT at runtime; older versions use install-time permissions.
    private fun withPermission(result: MethodChannel.Result, action: () -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
            action(); return
        }
        pendingPermission = action
        requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 42)
        // The action runs from onRequestPermissionsResult; reply now if it is denied there.
        pendingDenied = { result.error("permission", "Bluetooth permission was not granted.", null) }
    }

    private var pendingDenied: (() -> Unit)? = null

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 42) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) pendingPermission?.invoke() else pendingDenied?.invoke()
        pendingPermission = null
        pendingDenied = null
    }

    @SuppressLint("MissingPermission")
    private fun pairedDevices(result: MethodChannel.Result) {
        val a = adapter ?: return result.error("bluetooth", "This device has no Bluetooth.", null)
        if (!a.isEnabled) return result.error("bluetooth", "Bluetooth is off.", null)
        result.success(a.bondedDevices.map { mapOf("address" to it.address, "name" to (it.name ?: "?")) })
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String, result: MethodChannel.Result) {
        val a = adapter ?: return result.error("bluetooth", "This device has no Bluetooth.", null)
        close()
        Thread {
            try {
                a.cancelDiscovery()
                val device = a.getRemoteDevice(address)
                val s = try {
                    device.createRfcommSocketToServiceRecord(spp).also { it.connect() }
                } catch (e: IOException) {
                    // Fallback: the pedal's MIDI channel is RFCOMM 2 (verified on an MS-100BT).
                    val m = device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                    (m.invoke(device, 2) as BluetoothSocket).also { it.connect() }
                }
                socket = s
                startReader(s)
                main.post { result.success(null) }
            } catch (e: Exception) {
                close()
                main.post { result.error("connect", e.message ?: "Could not connect to the pedal.", null) }
            }
        }.start()
    }

    private fun startReader(s: BluetoothSocket) {
        reader = Thread {
            val buf = ByteArray(1024)
            try {
                val input = s.inputStream
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (n > 0) { val chunk = buf.copyOf(n); main.post { sink?.success(chunk) } }
                }
            } catch (_: IOException) {
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun write(bytes: ByteArray, result: MethodChannel.Result) {
        val s = socket ?: return result.error("closed", "Not connected.", null)
        Thread {
            try {
                s.outputStream.write(bytes)
                s.outputStream.flush()
                main.post { result.success(null) }
            } catch (e: IOException) {
                main.post { result.error("write", e.message, null) }
            }
        }.start()
    }

    private fun close() {
        try { socket?.close() } catch (_: IOException) {}
        socket = null
        reader = null
    }

    override fun onDestroy() {
        close()
        super.onDestroy()
    }
}
