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

        /** Low-battery warnings; see `low_battery_alerts.dart`. */
        private const val ALERTS_CHANNEL = "store.lyhoanganh.battery_holder/alerts"
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALERTS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Mirror the per-board settings so the background scan
                    // judges a sighting the way the foreground judges a sample.
                    "setLowBatteryAlerts" -> {
                        LowBatteryAlerts.saveSettings(
                            this,
                            settings = call.argument<String>("settings") ?: "{}",
                            samples = call.argument<Int>("samples") ?: 5,
                        )
                        result.success(true)
                    }

                    // Dart applied the five-sample rule to a live reading; the
                    // repeat window is checked here, because this side is the
                    // only one that remembers it across a restart.
                    "postLowBatteryAlert" -> result.success(
                        LowBatteryAlerts.postIfDue(
                            this,
                            deviceId = call.argument<String>("deviceId") ?: "board",
                            title = call.argument<String>("title") ?: "Battery low",
                            body = call.argument<String>("body") ?: "",
                            repeatMinutes = call.argument<Int>("repeatMinutes") ?: 120,
                        )
                    )

                    // A board whose settings just changed must not sit out the
                    // rest of a window it earned under the old ones.
                    "clearLowBatteryWindow" -> {
                        LowBatteryAlerts.clearWindow(
                            this,
                            call.argument<String>("deviceId") ?: "",
                        )
                        result.success(true)
                    }

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
