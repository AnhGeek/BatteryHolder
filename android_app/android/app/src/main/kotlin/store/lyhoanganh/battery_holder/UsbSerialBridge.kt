package store.lyhoanganh.battery_holder

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * USB-host serial for the ESP ROM bootloader, spoken directly to Android's
 * UsbManager.
 *
 * There is no third-party dependency here on purpose: flashing depends on
 * driving DTR/RTS with precise timing (that pair is wired to EN/IO0 on every ESP
 * dev board, and is the only way to get the chip into download mode), and on
 * being able to switch baud mid-session. Both are worth owning outright.
 *
 * Four bridges cover essentially every ESP board: CDC-ACM (native USB on the
 * C3/S3, plus generic bridges), CP210x (DevKitC), CH34x (clones and most C3
 * boards) and FTDI.
 */
class UsbSerialBridge(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "store.lyhoanganh.battery_holder/usb_serial"
        const val EVENT_CHANNEL = "store.lyhoanganh.battery_holder/usb_serial/events"
        const val DEVICE_EVENT_CHANNEL =
            "store.lyhoanganh.battery_holder/usb_serial/devices"

        private const val ACTION_PERMISSION =
            "store.lyhoanganh.battery_holder.USB_PERMISSION"
    }

    private val manager get() = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())

    private var driver: SerialDriver? = null
    private var events: EventChannel.EventSink? = null

    /// Attach/detach, so the app can follow a board that re-enumerates.
    private var deviceEvents: EventChannel.EventSink? = null
    private var attachReceiver: BroadcastReceiver? = null

    private var reader: Thread? = null
    @Volatile private var reading = false

    // MARK: - Flutter plumbing

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        handle(call.method, call.arguments as? Map<*, *>, result)
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    /// A second stream, carrying "attached"/"detached" rather than bytes.
    ///
    /// Resetting an ESP with native USB takes its serial port down and brings a
    /// new one up under a different device id; without this the app would keep
    /// pointing at the one that went away.
    val deviceEventHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
            deviceEvents = sink
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, intent: Intent) {
                    val action = when (intent.action) {
                        UsbManager.ACTION_USB_DEVICE_ATTACHED -> "attached"
                        UsbManager.ACTION_USB_DEVICE_DETACHED -> "detached"
                        else -> return
                    }
                    if (action == "detached") close()
                    main.post { deviceEvents?.success(action) }
                }
            }
            attachReceiver = receiver
            val filter = IntentFilter().apply {
                addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
                addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
        }

        override fun onCancel(arguments: Any?) {
            attachReceiver?.let { runCatching { context.unregisterReceiver(it) } }
            attachReceiver = null
            deviceEvents = null
        }
    }

    private fun handle(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        try {
            when (method) {
                "list" -> result.success(listDevices())
                "hasPermission" -> {
                    val device = deviceById(intArg(args, "deviceId"))
                    result.success(device != null && manager.hasPermission(device))
                }
                "requestPermission" -> requestPermission(intArg(args, "deviceId"), result)
                "open" -> result.success(
                    open(intArg(args, "deviceId"), intArg(args, "baudRate", 115200))
                )
                "setBaudRate" -> {
                    driver?.setBaudRate(intArg(args, "baudRate", 115200))
                    result.success(true)
                }
                "setControlLines" -> {
                    driver?.setControlLines(
                        boolArg(args, "dtr"), boolArg(args, "rts")
                    )
                    result.success(true)
                }
                "write" -> {
                    val bytes = args?.get("data") as? ByteArray
                        ?: return result.error("args", "write needs data", null)
                    result.success(driver?.write(bytes) ?: -1)
                }
                "close" -> {
                    close()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("usb", e.message ?: e.toString(), null)
        }
    }

    private fun intArg(args: Map<*, *>?, key: String, fallback: Int = -1): Int =
        (args?.get(key) as? Number)?.toInt() ?: fallback

    private fun boolArg(args: Map<*, *>?, key: String): Boolean =
        args?.get(key) as? Boolean ?: false

    // MARK: - Devices

    private fun listDevices(): List<Map<String, Any?>> =
        manager.deviceList.values.mapNotNull { device ->
            val kind = driverKind(device) ?: return@mapNotNull null
            mapOf(
                "deviceId" to device.deviceId,
                "vid" to device.vendorId,
                "pid" to device.productId,
                "product" to device.productName,
                "manufacturer" to device.manufacturerName,
                "serial" to runCatching {
                    if (manager.hasPermission(device)) device.serialNumber else null
                }.getOrNull(),
                "driver" to kind,
                "hasPermission" to manager.hasPermission(device)
            )
        }

    private fun deviceById(id: Int): UsbDevice? =
        manager.deviceList.values.firstOrNull { it.deviceId == id }

    /** Which bridge chip this is, or null when it is not a serial device at all. */
    private fun driverKind(device: UsbDevice): String? = when {
        device.vendorId == 0x10C4 -> "cp210x"
        device.vendorId == 0x1A86 -> "ch34x"
        device.vendorId == 0x0403 -> "ftdi"
        device.vendorId == 0x303A -> "cdc"      // Espressif native USB
        hasCdcInterface(device) -> "cdc"
        else -> null
    }

    private fun hasCdcInterface(device: UsbDevice): Boolean {
        for (i in 0 until device.interfaceCount) {
            val cls = device.getInterface(i).interfaceClass
            if (cls == UsbConstants.USB_CLASS_COMM || cls == UsbConstants.USB_CLASS_CDC_DATA) {
                return true
            }
        }
        return false
    }

    private fun requestPermission(deviceId: Int, result: MethodChannel.Result) {
        val device = deviceById(deviceId)
        if (device == null) {
            result.success(false)
            return
        }
        if (manager.hasPermission(device)) {
            result.success(true)
            return
        }

        var settled = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != ACTION_PERMISSION) return
                context.unregisterReceiver(this)
                if (settled) return
                settled = true
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                main.post { result.success(granted) }
            }
        }
        val filter = IntentFilter(ACTION_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_MUTABLE else 0
        val intent = PendingIntent.getBroadcast(
            context, 0, Intent(ACTION_PERMISSION).setPackage(context.packageName), flags
        )
        manager.requestPermission(device, intent)
    }

    // MARK: - Session

    private fun open(deviceId: Int, baudRate: Int): Boolean {
        close()
        val device = deviceById(deviceId) ?: return false
        if (!manager.hasPermission(device)) return false
        val connection = manager.openDevice(device) ?: return false

        val kind = driverKind(device) ?: "cdc"
        val serial = when (kind) {
            "cp210x" -> Cp210xDriver(device, connection)
            "ch34x" -> Ch34xDriver(device, connection)
            "ftdi" -> FtdiDriver(device, connection)
            else -> CdcAcmDriver(device, connection)
        }
        if (!serial.open(baudRate)) {
            connection.close()
            return false
        }
        driver = serial
        startReader(serial)
        return true
    }

    private fun startReader(serial: SerialDriver) {
        reading = true
        reader = thread(name = "usb-serial-read", isDaemon = true) {
            val buffer = ByteArray(4096)
            while (reading) {
                val read = try {
                    serial.read(buffer, 50)
                } catch (e: Exception) {
                    -1
                }
                if (read > 0) {
                    val chunk = buffer.copyOf(read)
                    main.post { events?.success(chunk) }
                } else if (read < 0 && !reading) {
                    break
                }
            }
        }
    }

    fun close() {
        reading = false
        reader?.join(300)
        reader = null
        driver?.close()
        driver = null
    }
}

// MARK: - Drivers

private abstract class SerialDriver(
    protected val device: UsbDevice,
    protected val connection: UsbDeviceConnection
) {
    protected var readEndpoint: UsbEndpoint? = null
    protected var writeEndpoint: UsbEndpoint? = null
    protected val claimed = mutableListOf<UsbInterface>()

    abstract fun open(baudRate: Int): Boolean
    abstract fun setBaudRate(baudRate: Int)
    abstract fun setControlLines(dtr: Boolean, rts: Boolean)

    open fun read(buffer: ByteArray, timeoutMs: Int): Int {
        val endpoint = readEndpoint ?: return -1
        return connection.bulkTransfer(endpoint, buffer, buffer.size, timeoutMs)
    }

    open fun write(data: ByteArray): Int {
        val endpoint = writeEndpoint ?: return -1
        var sent = 0
        while (sent < data.size) {
            val chunk = data.copyOfRange(sent, minOf(data.size, sent + 4096))
            val wrote = connection.bulkTransfer(endpoint, chunk, chunk.size, 3000)
            if (wrote <= 0) break
            sent += wrote
        }
        return sent
    }

    open fun close() {
        claimed.forEach { runCatching { connection.releaseInterface(it) } }
        claimed.clear()
        runCatching { connection.close() }
    }

    /** Claims every interface and picks the first bulk in/out endpoint pair. */
    protected fun claimBulkEndpoints(): Boolean {
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            if (!connection.claimInterface(iface, true)) continue
            claimed.add(iface)
            for (e in 0 until iface.endpointCount) {
                val endpoint = iface.getEndpoint(e)
                if (endpoint.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (endpoint.direction == UsbConstants.USB_DIR_IN && readEndpoint == null) {
                    readEndpoint = endpoint
                } else if (endpoint.direction == UsbConstants.USB_DIR_OUT && writeEndpoint == null) {
                    writeEndpoint = endpoint
                }
            }
        }
        return readEndpoint != null && writeEndpoint != null
    }

    protected fun control(
        requestType: Int, request: Int, value: Int, index: Int, data: ByteArray? = null
    ): Int = connection.controlTransfer(
        requestType, request, value, index, data, data?.size ?: 0, 2000
    )
}

/** USB CDC-ACM — the ESP32-C3/S3 native USB port, and generic bridges. */
private class CdcAcmDriver(device: UsbDevice, connection: UsbDeviceConnection) :
    SerialDriver(device, connection) {

    private var controlIndex = 0

    override fun open(baudRate: Int): Boolean {
        // The line-coding request goes to the comm interface, not the data one.
        for (i in 0 until device.interfaceCount) {
            if (device.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_COMM) {
                controlIndex = device.getInterface(i).id
                break
            }
        }
        if (!claimBulkEndpoints()) return false
        setBaudRate(baudRate)
        // Park DTR/RTS deasserted. They are wired to IO0/EN, so opening a port
        // with either asserted resets the board — which must only ever happen
        // when we ask for it.
        setControlLines(dtr = false, rts = false)
        return true
    }

    override fun setBaudRate(baudRate: Int) {
        val payload = byteArrayOf(
            (baudRate and 0xFF).toByte(),
            ((baudRate shr 8) and 0xFF).toByte(),
            ((baudRate shr 16) and 0xFF).toByte(),
            ((baudRate shr 24) and 0xFF).toByte(),
            0,      // 1 stop bit
            0,      // no parity
            8       // 8 data bits
        )
        control(0x21, 0x20, 0, controlIndex, payload)   // SET_LINE_CODING
    }

    override fun setControlLines(dtr: Boolean, rts: Boolean) {
        val value = (if (dtr) 0x01 else 0) or (if (rts) 0x02 else 0)
        control(0x21, 0x22, value, controlIndex)        // SET_CONTROL_LINE_STATE
    }
}

/** Silicon Labs CP2102/CP2104 — the bridge on the ESP32 DevKitC. */
private class Cp210xDriver(device: UsbDevice, connection: UsbDeviceConnection) :
    SerialDriver(device, connection) {

    override fun open(baudRate: Int): Boolean {
        if (!claimBulkEndpoints()) return false
        control(0x41, 0x00, 0x0001, 0)                  // IFC_ENABLE
        control(0x41, 0x03, 0x0800, 0)                  // SET_LINE_CTL: 8N1
        setBaudRate(baudRate)
        setControlLines(dtr = false, rts = false)       // do not reset on open
        return true
    }

    override fun setBaudRate(baudRate: Int) {
        val payload = byteArrayOf(
            (baudRate and 0xFF).toByte(),
            ((baudRate shr 8) and 0xFF).toByte(),
            ((baudRate shr 16) and 0xFF).toByte(),
            ((baudRate shr 24) and 0xFF).toByte()
        )
        control(0x40, 0x1E, 0, 0, payload)              // SET_BAUDRATE
    }

    override fun setControlLines(dtr: Boolean, rts: Boolean) {
        // Low byte sets the lines, high byte says which of them to act on.
        val value = (if (dtr) 0x01 else 0) or (if (rts) 0x02 else 0) or 0x0300
        control(0x41, 0x07, value, 0)                   // SET_MHS
    }

    override fun close() {
        runCatching { control(0x41, 0x00, 0x0000, 0) }  // IFC_DISABLE
        super.close()
    }
}

/** WCH CH340/CH341 — clones, and most C3 boards with a bridge. */
private class Ch34xDriver(device: UsbDevice, connection: UsbDeviceConnection) :
    SerialDriver(device, connection) {

    private var handshake = 0

    override fun open(baudRate: Int): Boolean {
        if (!claimBulkEndpoints()) return false
        val scratch = ByteArray(2)
        control(0xC0, 0x5F, 0, 0, scratch)              // read version
        control(0x40, 0xA1, 0, 0)                       // init
        setBaudRate(baudRate)
        control(0x40, 0xA1, 0x501F, 0xD90A)             // 8N1
        setControlLines(dtr = false, rts = false)
        return true
    }

    override fun setBaudRate(baudRate: Int) {
        // Divisor maths from the in-tree Linux ch341 driver.
        var factor = 1532620800 / baudRate
        var divisor = 3
        while (factor > 0xFFF0 && divisor > 0) {
            factor = factor shr 3
            divisor--
        }
        factor = 0x10000 - factor
        val a = (factor and 0xFF00) or divisor
        val b = factor and 0xFF
        control(0x40, 0x9A, 0x1312, a)
        control(0x40, 0x9A, 0x0F2C, b)
    }

    override fun setControlLines(dtr: Boolean, rts: Boolean) {
        // The CH34x modem-control byte is active low.
        handshake = (if (dtr) 0x20 else 0) or (if (rts) 0x40 else 0)
        control(0x40, 0xA4, handshake.inv() and 0xFF, 0)
    }
}

/** FTDI FT232 — older dev boards and USB-UART cables. */
private class FtdiDriver(device: UsbDevice, connection: UsbDeviceConnection) :
    SerialDriver(device, connection) {

    override fun open(baudRate: Int): Boolean {
        if (!claimBulkEndpoints()) return false
        control(0x40, 0x00, 0x0000, 1)                  // reset
        control(0x40, 0x04, 0x0008, 1)                  // 8N1
        setBaudRate(baudRate)
        setControlLines(dtr = false, rts = false)       // do not reset on open
        return true
    }

    override fun setBaudRate(baudRate: Int) {
        val (value, index) = ftdiDivisor(baudRate)
        control(0x40, 0x03, value, index)
    }

    override fun setControlLines(dtr: Boolean, rts: Boolean) {
        // Each line is set by its own request: low byte state, high byte mask.
        control(0x40, 0x01, if (dtr) 0x0101 else 0x0100, 1)
        control(0x40, 0x01, if (rts) 0x0202 else 0x0200, 1)
    }

    /** The FT232's 14-bit integer + 3-bit fractional divisor encoding. */
    private fun ftdiDivisor(baudRate: Int): Pair<Int, Int> {
        val fractionBits = intArrayOf(0, 3, 2, 4, 1, 5, 6, 7)
        val divisor = 24_000_000 / baudRate           // 3 MHz base, 8 sub-steps
        var value = divisor shr 3
        value = value or (fractionBits[divisor and 0x07] shl 14)
        var index = 1
        if (value and 0x10000 != 0) {                  // 17th bit lives in index
            value = value and 0xFFFF
            index = index or 0x0100
        }
        return Pair(value, index)
    }

    /**
     * Every FTDI read starts with two modem-status bytes that are not data.
     */
    override fun read(buffer: ByteArray, timeoutMs: Int): Int {
        val endpoint = readEndpoint ?: return -1
        val scratch = ByteArray(buffer.size)
        val read = connection.bulkTransfer(endpoint, scratch, scratch.size, timeoutMs)
        if (read <= 2) return 0
        System.arraycopy(scratch, 2, buffer, 0, read - 2)
        return read - 2
    }
}
