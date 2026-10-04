package dev.karthikkunal.system_dns

import android.net.DnsResolver
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Answers DNS queries through [DnsResolver] and returns the raw response bytes.
 *
 * `rawQuery` is used rather than `query` because `query` resolves to
 * `InetAddress` and so can only ever answer A/AAAA, while the discovery engine
 * needs MX, NS, TXT and CAA for SPF/DMARC/DKIM. `rawQuery`'s callback is
 * generic over its answer type and yields the full DNS response, so arbitrary
 * record types survive. Decoding those bytes is done once in Dart, so no DNS
 * message parsing is duplicated per platform.
 *
 * The `rawQuery` overload taking an [Executor] is asynchronous, so the lookup
 * does not block the thread that starts it and no worker pool is needed here.
 */
class SystemDnsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    /**
     * [MethodChannel.Result] must be invoked on the main thread, and the
     * resolver delivers its callback on whatever executor it is handed, so
     * callbacks are routed straight to the main thread.
     */
    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { command -> mainHandler.post(command) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "system_dns")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        mainHandler.removeCallbacksAndMessages(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "ping" -> result.success(null)
            "query" -> {
                val name = call.argument<String>("name")
                val type = call.argument<Int>("type")
                val timeoutMs = call.argument<Int>("timeoutMs") ?: DEFAULT_TIMEOUT_MS
                if (name.isNullOrBlank() || type == null) {
                    result.error(
                        "BAD_ARGUMENTS",
                        "A non-blank name and an integer type are required.",
                        null,
                    )
                    return
                }
                query(name, type, timeoutMs, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun isSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun query(
        name: String,
        type: Int,
        timeoutMs: Int,
        result: MethodChannel.Result,
    ) {
        if (!isSupported()) {
            result.error(
                "UNSUPPORTED",
                "android.net.DnsResolver requires API 29 or newer.",
                null,
            )
            return
        }

        // A timeout can be reported after the answer has already been delivered,
        // so the first outcome to arrive wins and the rest are dropped. Without
        // this the MethodChannel would be completed twice.
        val answered = AtomicBoolean(false)

        try {
            DnsResolver.getInstance().rawQuery(
                // A null network selects the system default, which is what a
                // resolver lookup should follow: the same path any other app on
                // the device uses.
                null, // network
                name,
                type,
                0, // flags
                timeoutMs,
                mainExecutor,
                null, // CancellationSignal; the query timeout covers this
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, responseCode: Int) {
                        if (!answered.compareAndSet(false, true)) return
                        if (answer.isEmpty()) {
                            result.error(
                                "EMPTY_RESPONSE",
                                "The resolver returned no data for $name.",
                                null,
                            )
                            return
                        }
                        // The DNS rcode travels inside these bytes and is read
                        // by the Dart parser, so it is not reinterpreted here.
                        result.success(answer.toList())
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        if (!answered.compareAndSet(false, true)) return
                        result.error(
                            "QUERY_FAILED",
                            "The resolver failed for $name (code ${error.code}).",
                            error.code,
                        )
                    }
                },
            )
        } catch (error: Exception) {
            if (answered.compareAndSet(false, true)) {
                result.error("QUERY_FAILED", error.message ?: error.toString(), null)
            }
        }
    }

    private companion object {
        const val DEFAULT_TIMEOUT_MS = 10_000
    }
}
