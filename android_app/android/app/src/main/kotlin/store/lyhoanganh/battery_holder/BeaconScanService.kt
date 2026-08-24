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
         * A gap this long between sightings means the board slept in between,
         * so the next one starts a new wake and earns a row.
         *
         * The board re-reads its ADC and rebuilds the advertisement every 10 s
         * while it is awake, so sightings inside one wake arrive ~10 s apart
         * and almost never carry the same payload twice. Collapsing on the gap
         * rather than on the payload is what keeps this at one row per wake:
         * the log is meant to be a wake history, not an ADC trace.
         *
         * Sits between that 10 s refresh and the shortest wake interval the app
         * offers (30 s), so no wake is ever mistaken for a continuation.
         */
        private const val WAKE_GAP_MS = 25_000L

        /**
         * A board that never sleeps — one held awake by an open BLE session —
         * would otherwise log nothing after its first sighting. Record it this
         * often so the row count still tracks something.
         */
        private const val MAX_QUIET_MS = 15 * 60_000L

        private const val CHANNEL_ID = "beacon_scan"
        private const val NOTIFICATION_ID = 42

        private const val TAG = "BeaconScanService"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var scanner: BluetoothLeScanner? = null

    /** What we know about a board between sightings, for the wake test below. */
    private data class Seen(val at: Long, val written: Long, val flags: Int)

    /** deviceId -> its last sighting, written or not. */
    private val lastSeen = HashMap<String, Seen>()

    /** Rows appended since the last trim, so we don't stat the file every hit. */
    private var appendsSinceTrim = 0

    /** Consecutive logged wakes below the alert threshold, per board. */
    private val lowRuns = HashMap<String, Int>()

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

        val now = System.currentTimeMillis()
        val previous = lastSeen[deviceId]
        // First sighting, a fresh wake, a mode change (§2.1 flags) or a board
        // that has stayed awake too long to leave unrecorded.
        val worthLogging = previous == null ||
            now - previous.at >= WAKE_GAP_MS ||
            flags != previous.flags ||
            now - previous.written >= MAX_QUIET_MS
        // Every sighting moves the clock, logged or not: the gap that matters
        // is the one the board was invisible for, not the one since a row.
        lastSeen[deviceId] = Seen(
            at = now,
            written = if (worthLogging) now else previous!!.written,
            flags = flags,
        )
        if (!worthLogging) return

        if (millivolts != null) checkLowBattery(deviceId, name, millivolts / 1000.0)

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

    // --------------------------------------------------------------- alert --

    /**
     * Apply the low-battery rule to one *wake*.
     *
     * Counted per logged row rather than per sighting, and that is the whole
     * design: a board rebuilds its advertisement every 10 s while it is awake,
     * so counting sightings would reach five inside a single 20-second wake and
     * warn about a pack that had one bad minute. One row is one wake, so five
     * rows is five wakes — minutes to hours apart — which is a pack that really
     * is going flat.
     *
     * The run is held in memory: if Android kills the service the count starts
     * again, which costs at most a few extra wakes before a warning that was
     * going to fire anyway. The repeat window is *not* held here — that lives
     * in prefs, so a service restart cannot turn one flat pack into a stream
     * of notifications.
     */
    private fun checkLowBattery(deviceId: String, name: String, volts: Double) {
        val setting = LowBatteryAlerts.settingFor(this, deviceId) ?: return

        if (volts >= setting.thresholdVolts) {
            lowRuns.remove(deviceId)
            return
        }

        val samples = LowBatteryAlerts.samplesBeforeAlert(this)
        // Clamped: once a board is over the line the only question left is
        // whether its repeat window has passed, which `postIfDue` answers.
        val run = minOf((lowRuns[deviceId] ?: 0) + 1, samples)
        lowRuns[deviceId] = run
        if (run < samples) return

        val label = if (name.isEmpty()) deviceId else name
        LowBatteryAlerts.postIfDue(
            this,
            deviceId = deviceId,
            title = "Battery low",
            body = "%s is at %.2f V — %d readings in a row below %.2f V.".format(
                label, volts, samples, setting.thresholdVolts
            ),
            repeatMinutes = setting.repeatMinutes,
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
