package com.anthonyessaye.ms100bt_link

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
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
    /** Calls waiting for a permission answer (several can arrive together, e.g. at launch). */
    private val waiting = mutableListOf<Triple<Array<String>, () -> Unit, () -> Unit>>()
    private var asked = mutableSetOf<String>()

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
            "pairedDevices" -> withPermissions(connectPermissions, result) { pairedDevices(result) }
            "connect" -> withPermissions(connectPermissions, result) { connect(call.argument<String>("address") ?: "", result) }
            "scan" -> withPermissions(scanPermissions, result) { scan(result) }
            "pair" -> withPermissions(connectPermissions + scanPermissions, result) { pair(call.argument<String>("address") ?: "", result) }
            "permissions" -> result.success(permissionState())
            "ensureScanPermission" -> withPermissions(scanPermissions, result) { result.success(true) }
            "openSettings" -> {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
                result.success(null)
            }
            "enableBluetooth" -> withPermissions(connectPermissions, result) { enableBluetooth(result) }
            "write" -> write(call.arguments as ByteArray, result)
            "disconnect" -> { close(); result.success(null) }
            "diagnostics" -> result.success(mapOf("platform" to "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})",
                                                  "bluetooth" to if (adapter?.isEnabled == true) "on" else "off",
                                                  "permissions" to permissionState().entries.joinToString { "${it.key}: ${it.value}" }))
            else -> result.notImplemented()
        }
    }

    // Runtime permissions: Android 12+ uses BLUETOOTH_CONNECT / BLUETOOTH_SCAN; Android 11 and older
    // need location to discover devices (bonded devices and connecting need nothing at runtime).
    private val connectPermissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) arrayOf(Manifest.permission.BLUETOOTH_CONNECT) else arrayOf()
    private val scanPermissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
                else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** granted / denied / blocked (denied with "don't ask again": only Settings can change it). */
    private fun permissionState(): Map<String, String> = (connectPermissions + scanPermissions).distinct().associate { p ->
        p.substringAfterLast('.') to when {
            granted(p) -> "granted"
            p in asked && !shouldShowRequestPermissionRationale(p) -> "blocked"
            else -> "denied"
        }
    }

    private fun withPermissions(perms: Array<String>, result: MethodChannel.Result, action: () -> Unit) {
        val missing = perms.filterNot(::granted).toTypedArray()
        if (missing.isEmpty()) { action(); return }
        val deny = {
            val blocked = missing.any { it in asked && !shouldShowRequestPermissionRationale(it) }
            result.error(if (blocked) "permission_blocked" else "permission",
                         if (blocked) "Bluetooth permission is turned off for this app. Turn on Nearby devices in Settings."
                         else "Bluetooth permission was not granted.", null)
        }
        val first = waiting.isEmpty()
        waiting.add(Triple(missing, action, deny))
        if (first) requestPermissions(missing, 42)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 42) return
        asked.addAll(permissions)
        val pending = waiting.toList()
        waiting.clear()
        // Answer every waiting call; ask again only for permissions a later call needs that were not part of this request.
        val again = pending.filter { (perms, _, _) -> perms.any { !granted(it) && it !in permissions } }
        for (w in pending - again.toSet()) if (w.first.all(::granted)) w.second() else w.third()
        if (again.isNotEmpty()) {
            waiting.addAll(again)
            requestPermissions(again.flatMap { it.first.filterNot(::granted) }.distinct().toTypedArray(), 42)
        }
    }

    @SuppressLint("MissingPermission")
    private fun enableBluetooth(result: MethodChannel.Result) {
        if (adapter?.isEnabled == true) return result.success(true)
        startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
        result.success(false)
    }

    /** Discovers nearby Bluetooth devices for 12 s (the pedal must be in pairing mode to show up). */
    @SuppressLint("MissingPermission")
    private fun scan(result: MethodChannel.Result) {
        val a = adapter ?: return result.error("bluetooth", "This device has no Bluetooth.", null)
        if (!a.isEnabled) return result.error("bluetooth_off", "Bluetooth is off.", null)
        val found = linkedMapOf<String, Map<String, Any>>()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val d: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                                          else @Suppress("DEPRECATION") i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                if (d != null) found[d.address] = mapOf("address" to d.address, "name" to (d.name ?: d.address),
                                                         "paired" to (d.bondState == BluetoothDevice.BOND_BONDED))
            }
        }
        registerReceiver(receiver, IntentFilter(BluetoothDevice.ACTION_FOUND))
        a.cancelDiscovery()
        if (!a.startDiscovery()) {
            unregisterReceiver(receiver)
            return result.error("scan", "Could not start a Bluetooth scan.", null)
        }
        main.postDelayed({
            a.cancelDiscovery()
            try { unregisterReceiver(receiver) } catch (_: Exception) {}
            result.success(found.values.toList())
        }, 12_000)
    }

    /** Pairs with a discovered device; replies when pairing finishes (or fails / times out). */
    @SuppressLint("MissingPermission")
    private fun pair(address: String, result: MethodChannel.Result) {
        val a = adapter ?: return result.error("bluetooth", "This device has no Bluetooth.", null)
        val device = a.getRemoteDevice(address)
        if (device.bondState == BluetoothDevice.BOND_BONDED) return result.success(true)
        var done = false
        lateinit var receiver: BroadcastReceiver
        fun finish(ok: Boolean) {
            if (done) return
            done = true
            try { unregisterReceiver(receiver) } catch (_: Exception) {}
            result.success(ok)
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val d: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                                          else @Suppress("DEPRECATION") i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                if (d?.address != address) return
                when (i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)) {
                    BluetoothDevice.BOND_BONDED -> finish(true)
                    BluetoothDevice.BOND_NONE -> finish(false)
                }
            }
        }
        registerReceiver(receiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
        a.cancelDiscovery()
        if (!device.createBond()) finish(false)
        main.postDelayed({ finish(device.bondState == BluetoothDevice.BOND_BONDED) }, 60_000)
    }

    @SuppressLint("MissingPermission")
    private fun pairedDevices(result: MethodChannel.Result) {
        val a = adapter ?: return result.error("bluetooth", "This device has no Bluetooth.", null)
        if (!a.isEnabled) return result.error("bluetooth_off", "Bluetooth is off.", null)
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
