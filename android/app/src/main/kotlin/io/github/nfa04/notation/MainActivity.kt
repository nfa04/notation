package io.github.nfa04.notation

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.net.ConnectivityManager
import android.os.BatteryManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.Display
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// (a fragment activity, which the fingerprint dialog of local_auth needs)
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        turnShareIntoLink(intent)
        super.onCreate(savedInstanceState)
        getSystemService(DisplayManager::class.java)?.registerDisplayListener(displayChanges, null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // the settings of the refresh rate (lib/style/refresh_rate.dart): sent at the start of the app and after each change
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notation/display").setMethodCallHandler { call, result ->
            if (call.method == "highRefresh") {
                highRefresh = call.argument<Boolean>("on") ?: false
                offBelowBattery = call.argument<Int>("offBelowBattery")
                followBattery(highRefresh && offBelowBattery != null)
                applyRefreshRate()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        // the battery and whether the network is paid by the amount, for a live session (lib/collab/device_budget.dart): a device that is
        // low or metered does not take over hosting
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notation/device").setMethodCallHandler { call, result ->
            if (call.method == "budget") result.success(deviceBudget()) else result.notImplemented()
        }
    }

    private fun deviceBudget(): Map<String, Any?> {
        val answer = HashMap<String, Any?>()
        // (a sticky broadcast, read without a receiver: the state as it is now)
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if (battery != null) {
            val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            if (level >= 0 && scale > 0) answer["percent"] = level * 100 / scale
            val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            if (status != -1) {
                answer["charging"] = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
            }
        }
        try {
            getSystemService(ConnectivityManager::class.java)?.let { answer["metered"] = it.isActiveNetworkMetered }
        } catch (e: SecurityException) {
            // (no permission to look: the Dart side guesses from the kind of network)
        }
        return answer
    }

    override fun onDestroy() {
        getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(displayChanges)
        followBattery(false)
        super.onDestroy()
    }

    // Flutter draws at the rate of the display mode Android gives the window, and does not ask for one: some devices keep an app that
    // does not ask at 60 Hz on a screen that can do 90 or 120. When the person turned it on (off by default: it costs battery), the window
    // asks for the fastest mode at the resolution the screen has now, never another resolution; below the battery level they chose it
    // gives the choice back to Android, and asks again once the battery is above it. Android may still slow it down (battery saver).
    private var highRefresh = false
    private var offBelowBattery: Int? = null
    private var batteryPercent: Int? = null

    private fun applyRefreshRate() {
        if (Build.VERSION.SDK_INT < 23) return
        val low = offBelowBattery?.let { limit -> batteryPercent?.let { it < limit } } ?: false
        val wanted = if (highRefresh && !low) fastestModeId() else 0 // (0: no wish, Android decides)
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId == wanted) return
        attributes.preferredDisplayModeId = wanted
        window.attributes = attributes
    }

    private fun fastestModeId(): Int {
        if (Build.VERSION.SDK_INT < 23) return 0
        val display = currentDisplay() ?: return 0
        val now = display.mode
        return display.supportedModes
            .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
            .maxByOrNull { it.refreshRate }?.modeId ?: 0
    }

    private val batteryChanges = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            batteryPercent = if (level >= 0 && scale > 0) level * 100 / scale else null
            applyRefreshRate()
        }
    }
    private var followingBattery = false

    // (the battery is only followed while a level is set: the broadcast comes at every change of a percent)
    private fun followBattery(on: Boolean) {
        if (on == followingBattery) return
        followingBattery = on
        if (on) {
            // a sticky broadcast: the level as it is now comes at once
            registerReceiver(batteryChanges, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } else {
            unregisterReceiver(batteryChanges)
            batteryPercent = null
        }
    }

    // (the resolution was changed in the settings, or the window went to another screen: the fastest mode is picked again for it)
    private val displayChanges = object : DisplayManager.DisplayListener {
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == currentDisplay()?.displayId) applyRefreshRate()
        }

        override fun onDisplayAdded(displayId: Int) {}

        override fun onDisplayRemoved(displayId: Int) {}
    }

    @Suppress("DEPRECATION")
    private fun currentDisplay(): Display? = if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay

    override fun onNewIntent(intent: Intent) {
        turnShareIntoLink(intent)
        super.onNewIntent(intent)
    }

    // What another app shares (text, a web address, a picture, a PDF) is handed to the Dart side the way the other links are: as a
    // notation://capture link that app_links delivers. A shared file is copied to the cache folder first, because the address the
    // sender gave is only readable for a while; the Dart side takes files from that folder only.
    private fun turnShareIntoLink(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_SEND) return
        val link = Uri.Builder().scheme("notation").authority("capture")
        intent.getStringExtra(Intent.EXTRA_TEXT)?.let { link.appendQueryParameter("text", it.take(100_000)) }
        intent.getStringExtra(Intent.EXTRA_SUBJECT)?.let { link.appendQueryParameter("title", it) }
        sharedStream(intent)?.let { uri -> copyToCache(uri)?.let { link.appendQueryParameter("file", it.absolutePath) } }
        intent.action = Intent.ACTION_VIEW
        intent.data = link.build()
    }

    @Suppress("DEPRECATION")
    private fun sharedStream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    private fun copyToCache(uri: Uri): File? {
        return try {
            var name: String? = null
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) name = cursor.getString(0)
            }
            var safe = (name ?: "shared").replace(Regex("[^A-Za-z0-9._ -]"), "_")
            if (!safe.contains('.')) {
                MimeTypeMap.getSingleton().getExtensionFromMimeType(contentResolver.getType(uri))?.let { safe = "$safe.$it" }
            }
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val out = File(dir, "${System.currentTimeMillis()}-$safe")
            val input = contentResolver.openInputStream(uri) ?: return null
            input.use { source -> out.outputStream().use { target -> source.copyTo(target) } }
            out
        } catch (e: Exception) {
            null
        }
    }
}
