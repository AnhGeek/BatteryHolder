package store.lyhoanganh.battery_holder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.os.ParcelUuid
import android.util.Log
import java.io.File
import java.util.UUID

/**
 * Foreground service that keeps logging BatteryHolder advertisements while the
 * app is backgrounded or swiped away.
 *
 * The board is awake for ~20 s every few minutes (DEVICE_PROTOCOL.md §1), so a
 * scan that only runs while a screen is open would miss almost every wake. A
 * foreground service is the only thing Android will let scan indefinitely.
 *
 * Rows are appended to the same JSON-lines file the Flutter side reads
 * (`BeaconLogStore`), so there is exactly one writer and no IPC to keep in sync.
 */
class BeaconScanService : Service() {

    companion object {
        const val ACTION_START = "store.lyhoanganh.battery_holder.START_BEACON_SCAN"
        const val ACTION_STOP = "store.lyhoanganh.battery_holder.STOP_BEACON_SCAN"

        /** Must match `BeaconLogStore.fileName` on the Dart side. */
        const val LOG_FILE_NAME = "beacons.jsonl"

        /** Must match `BeaconLogStore.maxEntries`. */
        const val MAX_ENTRIES = 4000

        /** Service UUID from DEVICE_PROTOCOL.md §2. */
        private val SERVICE_UUID: UUID =
            UUID.fromString("A1B2C3D4-0001-4A5B-8C6D-000000000000")

        /** Manufacturer-data company id the firmware advertises under (§2.1). */
        private const val COMPANY_ID = 0xFFFF

        /** First byte of our manufacturer payload. */
        private const val MARKER = 0x42.toByte()

        /**
         * A board repeats the same payload for its whole wake window, so log a
         * board again only when the payload changes or this long has passed.
         * With 5-minute wakes that works out at roughly one row per wake.
         */
        private const val MIN_INTERVAL_MS = 60_000L

        private const val CHANNEL_ID = "beacon_scan"
        private const val NOTIFICATION_ID = 42

        private const val TAG = "BeaconScanService"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var scanner: BluetoothLeScanner? = null

    /** deviceId -> (last write time, payload fingerprint) for throttling. */
    private val lastWrite = HashMap<String, Pair<Long, String>>()

    /** Rows appended since the last trim, so we don't stat the file every hit. */
    private var appendsSinceTrim = 0

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result ?: return
            handle(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>?) {
            results?.forEach { handle(it) }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.w(TAG, "scan failed: $errorCode")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopScanning()
            stopSelf()
            return START_NOT_STICKY
        }

        startForegroundCompat()
        startScanning()
        // Restart if Android kills us; that is the whole point of the service.
        return START_STICKY
    }

    override fun onDestroy() {
        stopScanning()
        super.onDestroy()
    }

    // ---------------------------------------------------------------- scan --

    private fun hasScanPermission(): Boolean {
        val needed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            android.Manifest.permission.BLUETOOTH_SCAN
        } else {
            android.Manifest.permission.ACCESS_FINE_LOCATION
        }
        return checkSelfPermission(needed) == PackageManager.PERMISSION_GRANTED
    }

    private fun startScanning() {
        if (isRunning) return
        if (!hasScanPermission()) {
            Log.w(TAG, "missing scan permission; not starting")
            return
        }

        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter: BluetoothAdapter? = manager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "bluetooth off; will retry when the service is restarted")
            return
        }

        val le = adapter.bluetoothLeScanner ?: return
        val filters = listOf(
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()
        )
        // BALANCED rather than LOW_LATENCY: this runs forever, and the board's
        // 20-second window is long enough to be caught by a duty-cycled scan.
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .build()

        try {
            le.startScan(filters, settings, callback)
            scanner = le
            isRunning = true
            Log.i(TAG, "scanning for BatteryHolder boards")
        } catch (e: SecurityException) {
            Log.w(TAG, "startScan denied: ${e.message}")
        }
    }

    private fun stopScanning() {
        try {
            if (isRunning) scanner?.stopScan(callback)
        } catch (e: SecurityException) {
            Log.w(TAG, "stopScan denied: ${e.message}")
        }
        scanner = null
        isRunning = false
    }

    // --------------------------------------------------------------- decode --

    private fun handle(result: ScanResult) {
        val record = result.scanRecord ?: return
        val payload = record.getManufacturerSpecificData(COMPANY_ID)

        // Guard on the marker: 0xFFFF is the reserved test id, so other vendors'
        // beacons can land here too.
        val valid = payload != null && payload.size >= 6 && payload[0] == MARKER

        val flags = if (valid) payload!![2].toInt() and 0xFF else 0
        val millivolts =
            if (valid) (payload!![3].toInt() and 0xFF) or ((payload[4].toInt() and 0xFF) shl 8)
            else null
        val soc = if (valid) payload!![5].toInt() and 0xFF else null

        val deviceId = result.device?.address ?: return
        val name = record.deviceName ?: ""

        val fingerprint = "$flags|$millivolts|$soc"
        val now = System.currentTimeMillis()
        val previous = lastWrite[deviceId]
        if (previous != null &&
            previous.second == fingerprint &&
            now - previous.first < MIN_INTERVAL_MS
        ) {
            return
        }
        lastWrite[deviceId] = Pair(now, fingerprint)

        append(
            buildString {
                append("{\"t\":").append(now)
                append(",\"id\":\"").append(escape(deviceId)).append('"')
                append(",\"n\":\"").append(escape(name)).append('"')
                append(",\"r\":").append(result.rssi)
                if (millivolts != null) {
                    append(",\"v\":").append(String.format("%.3f", millivolts / 1000.0))
                }
                if (soc != null) append(",\"s\":").append(soc)
                append(",\"f\":").append(flags)
                append('}')
            }
        )
    }

    private fun escape(raw: String): String =
        raw.replace("\\", "\\\\").replace("\"", "\\\"")

    // ------------------------------------------------------------- log file --

    private fun logFile(): File = File(filesDir, LOG_FILE_NAME)

    private fun append(line: String) {
        try {
            logFile().appendText(line + "\n")
            if (++appendsSinceTrim >= 200) {
                appendsSinceTrim = 0
                trim()
            }
        } catch (e: Exception) {
            Log.w(TAG, "log append failed: ${e.message}")
        }
    }

    /** Drop the oldest rows so the file cannot grow without bound. */
    private fun trim() {
        try {
            val file = logFile()
            if (!file.exists()) return
            val lines = file.readLines()
            if (lines.size <= MAX_ENTRIES) return
            file.writeText(
                lines.subList(lines.size - MAX_ENTRIES, lines.size)
                    .joinToString("\n", postfix = "\n")
            )
        } catch (e: Exception) {
            Log.w(TAG, "log trim failed: ${e.message}")
        }
    }

    // --------------------------------------------------------- notification --

    private fun startForegroundCompat() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Battery monitoring",
                // LOW: no sound, and collapsed in the shade.
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps logging board readings while the app is closed."
            }
            manager?.createNotificationChannel(channel)
        }

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification =
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("BatteryHolder")
                .setContentText("Logging board readings in the background")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentIntent(open)
                .setOngoing(true)
                .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}
