package store.lyhoanganh.battery_holder

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "store.lyhoanganh.battery_holder/beacon_scan"
    }

    /** USB-host serial, used to flash and calibrate a board over the cable. */
    private var usbSerial: UsbSerialBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val usb = UsbSerialBridge(this)
        usbSerial = usb
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UsbSerialBridge.METHOD_CHANNEL)
            .setMethodCallHandler(usb)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, UsbSerialBridge.EVENT_CHANNEL)
            .setStreamHandler(usb)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UsbSerialBridge.DEVICE_EVENT_CHANNEL
        ).setStreamHandler(usb.deviceEventHandler)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        setEnabled(true)
                        val intent = Intent(this, BeaconScanService::class.java).apply {
                            action = BeaconScanService.ACTION_START
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }

                    "stop" -> {
                        setEnabled(false)
                        startService(
                            Intent(this, BeaconScanService::class.java).apply {
                                action = BeaconScanService.ACTION_STOP
                            }
                        )
                        result.success(true)
                    }

                    // Whether the user has background logging switched on.
                    //
                    // Defaults to false: an unset flag means nobody has ever
                    // turned this on, and a switch that reads "on" while no
                    // service is running is worse than one that reads "off".
                    "isEnabled" -> result.success(
                        BootReceiver.prefs(this)
                            .getBoolean(BootReceiver.KEY_ENABLED, false)
                    )

                    // Whether a scan is actually in flight right now.
                    "isScanning" -> result.success(BeaconScanService.isRunning)

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        // A half-open bulk endpoint survives the activity and blocks the next
        // flash attempt, so hand the device back explicitly.
        usbSerial?.close()
        usbSerial = null
        super.onDestroy()
    }

    private fun setEnabled(enabled: Boolean) {
        BootReceiver.prefs(this).edit()
            .putBoolean(BootReceiver.KEY_ENABLED, enabled)
            .apply()
    }
}
