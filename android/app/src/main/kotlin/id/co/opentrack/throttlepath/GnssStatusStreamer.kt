package id.co.opentrack.throttlepath

import android.content.Context
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Streams what the GNSS receiver is doing up to Dart: how many satellites it can
 * hear, how many are actually contributing to the fix, and how long its first fix
 * took. Two event shapes over one channel — `{visible, usedInFix}` per
 * constellation report, `{ttffMillis}` once per acquisition.
 *
 * geolocator's `Position` carries no constellation information whatsoever, so
 * the "ACQUIRING GPS…" screen had nothing to show but an indefinite pill. This
 * is the only native code in the app besides the share channel.
 *
 * The callback is registered only while Dart is listening. The Dart provider is
 * `autoDispose` and watched by the acquiring readout alone, so the receiver is
 * queried for the few seconds that readout is on screen and never while the app
 * sits idle.
 */
class GnssStatusStreamer(context: Context, messenger: BinaryMessenger) :
    EventChannel.StreamHandler {

    private val locationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    /** GnssStatus callbacks land here; an EventSink must be fed on the main thread. */
    private val handler = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null
    private var callback: GnssStatus.Callback? = null

    init {
        EventChannel(messenger, CHANNEL).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        // A platform below API 24, a device with no GNSS chip, or a revoked
        // permission all end up the same way: the stream stays open and silent.
        // Dart reads "never reported" as "no constellation data" and falls back
        // to its satellite-free wording, which is the honest thing to show —
        // an error here is not something the rider can act on.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        callback = register()
    }

    override fun onCancel(arguments: Any?) {
        val cb = callback
        if (cb != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            locationManager?.unregisterGnssStatusCallback(cb)
        }
        callback = null
        sink = null
    }

    /** Returns the registered callback, or null if the platform refused it. */
    @RequiresApi(Build.VERSION_CODES.N)
    private fun register(): GnssStatus.Callback? {
        val manager = locationManager ?: return null
        val cb = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                var used = 0
                for (i in 0 until status.satelliteCount) {
                    if (status.usedInFix(i)) used++
                }
                emit(status.satelliteCount, used)
            }

            override fun onFirstFix(ttffMillis: Int) {
                // The receiver's own time-to-first-fix. Worth forwarding because
                // it cannot be reconstructed on the Dart side: a timer started
                // when Dart subscribed would measure our own subscription, not
                // when the chip began looking. Collected over a few rides it is
                // what lets the acquiring readout say how long a lock usually
                // costs on *this* phone.
                sink?.success(mapOf("ttffMillis" to ttffMillis))
            }

            override fun onStopped() {
                // The receiver powered down. Say so, rather than leaving the last
                // count on screen still looking live.
                emit(0, 0)
            }
        }
        return try {
            if (manager.registerGnssStatusCallback(cb, handler)) cb else null
        } catch (e: SecurityException) {
            // Location permission was revoked between the Dart-side check and here.
            null
        }
    }

    private fun emit(visible: Int, usedInFix: Int) {
        sink?.success(mapOf("visible" to visible, "usedInFix" to usedInFix))
    }

    companion object {
        private const val CHANNEL = "id.co.opentrack.throttlepath/gnss"
    }
}
