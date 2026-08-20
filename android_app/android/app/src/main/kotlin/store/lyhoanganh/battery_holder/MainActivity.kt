package store.lyhoanganh.battery_holder

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

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
    }

    override fun onDestroy() {
        // A half-open bulk endpoint survives the activity and blocks the next
        // flash attempt, so hand the device back explicitly.
        usbSerial?.close()
        usbSerial = null
        super.onDestroy()
    }
}
