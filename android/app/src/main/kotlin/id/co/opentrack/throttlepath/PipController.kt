package id.co.opentrack.throttlepath

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Android's Picture-in-Picture mode to Dart, so a recording ride can keep
 * showing live telemetry in a small floating window while the rider is in another
 * app (navigation, music, a call).
 *
 * Deliberately display-only. PiP content receives no touch events, so any controls
 * would have to be system-drawn [android.app.RemoteAction]s — icon + label, no
 * accent colour, and crucially **no press-and-hold**, which is the guard the app
 * uses to stop a mis-tap ending a ride. Rather than weaken that, the window shows
 * numbers and nothing else: tapping it restores the activity, where the real
 * controls (including hold-to-stop) live. That choice is why there is no
 * PendingIntent/BroadcastReceiver machinery here and why [PictureInPictureParams]
 * needs only an aspect ratio.
 *
 * Contract with Dart (`id.co.opentrack.throttlepath/pip`):
 *  - `isSupported()` -> Bool   — API level and device feature check
 *  - `setArmed(Bool)`          — a ride is live; enter PiP when the rider leaves
 *  - `onPipModeChanged(Bool)`  — pushed to Dart so it can swap the widget tree
 */
class PipController(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "id.co.opentrack.throttlepath/pip"

        /**
         * Window shape. Android clamps PiP to between 1:2.39 and 2.39:1, and a
         * request outside that band throws. 3:2 sits well inside it and leaves
         * enough height for the speed hero plus the distance/elapsed row beneath
         * its hairline — 16:9 renders that stack uncomfortably tight.
         */
        private val ASPECT_RATIO = Rational(3, 2)
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    /**
     * Whether a ride is currently live. Gates entry so that backgrounding the app
     * from History or Settings with nothing recording doesn't pop an empty window.
     */
    private var armed = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(isSupported())
                "setArmed" -> {
                    armed = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * PiP needs API 26, but the project's `minSdk` resolves to 24 (the Flutter
     * default), so this is a real check rather than a formality. The system-feature
     * test matters too: a device can be API 26+ and still not offer PiP (Android Go
     * and some OEM builds), and calling in that case throws.
     */
    private fun isSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(
                PackageManager.FEATURE_PICTURE_IN_PICTURE,
            )

    /**
     * Called from the activity's `onUserLeaveHint` — Home or Recents.
     *
     * Note what this deliberately does not cover: the screen turning off. There is
     * nothing to look at then, and the foreground service keeps recording either
     * way, so entering PiP would cost battery for no one's benefit.
     *
     * `setAutoEnterEnabled` would be the seamless way to do this, but it is API 31+
     * and the test device is API 28.
     */
    fun onUserLeaveHint() {
        if (!armed || !isSupported()) return
        try {
            activity.enterPictureInPictureMode(
                PictureInPictureParams.Builder()
                    .setAspectRatio(ASPECT_RATIO)
                    .build(),
            )
        } catch (e: IllegalStateException) {
            // The activity can't enter PiP right now — most often because the
            // rider switched this app's "Picture-in-picture" permission off in
            // system settings. Swallowed on purpose: the ride is still recording
            // and the foreground-service notification still carries it, so there
            // is nothing to tell them and nothing to recover.
        }
    }

    /** Relays the system's mode change so Dart can swap in (or out) the PiP card. */
    fun onPipModeChanged(inPip: Boolean) {
        channel.invokeMethod("onPipModeChanged", inPip)
    }
}
