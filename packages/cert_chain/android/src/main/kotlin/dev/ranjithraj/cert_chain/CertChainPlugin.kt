package dev.karthikkunal.cert_chain

import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.InetSocketAddress
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Captures the TLS certificate chain a server presents.
 *
 * The chain arrives with the handshake, so no extra network work is needed.
 * A permissive trust manager is used so the chain can be captured even when it
 * does not verify — the trust verdict is reported separately.
 */
class CertChainPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    /**
     * The handshake is blocking network I/O. Method calls arrive on the platform
     * (main) thread, where Android throws
     * [android.os.NetworkOnMainThreadException] for any socket work, so the
     * capture runs here and the result is posted back to the main thread —
     * [MethodChannel.Result] must be invoked there.
     *
     * A small fixed pool rather than a single thread: a scan fans out over
     * several hosts, and serialising them would make a scan take the sum of its
     * handshakes instead of the slowest one.
     */
    private val executor = Executors.newFixedThreadPool(4)
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "cert_chain")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "fetch") {
            result.notImplemented()
            return
        }

        val host = call.argument<String>("host")
        val port = call.argument<Int>("port") ?: 443
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 15000

        if (host.isNullOrEmpty()) {
            result.error("bad_args", "host is required", null)
            return
        }

        executor.execute {
            val payload = try {
                fetchChain(host, port, timeoutMs)
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("tls_error", error.message ?: error.toString(), null)
                }
                return@execute
            }
            mainHandler.post { result.success(payload) }
        }
    }

    private fun fetchChain(host: String, port: Int, timeoutMs: Int): Map<String, Any?> {
        // Try a real handshake first so trust can be reported; if it fails,
        // capture permissively so an invalid chain is still reported.
        val trusted = try {
            capture(host, port, timeoutMs, permissive = false)
            true
        } catch (error: Exception) {
            false
        }

        val certificates = capture(host, port, timeoutMs, permissive = true)
        val encoded = certificates.map {
            Base64.encodeToString(it.encoded, Base64.NO_WRAP)
        }

        return mapOf(
            "trusted" to trusted,
            "certs" to encoded,
        )
    }

    private fun capture(
        host: String,
        port: Int,
        timeoutMs: Int,
        permissive: Boolean,
    ): List<X509Certificate> {
        val context = SSLContext.getInstance("TLS")
        val trustManagers: Array<TrustManager>? = if (permissive) {
            arrayOf(object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
                override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            })
        } else {
            null
        }
        context.init(null, trustManagers, null)

        val socket = context.socketFactory.createSocket() as SSLSocket
        try {
            socket.connect(InetSocketAddress(host, port), timeoutMs)
            socket.soTimeout = timeoutMs

            // Capture the chain even when the hostname does not match.
            val params = socket.sslParameters
            params.endpointIdentificationAlgorithm = null
            socket.sslParameters = params

            socket.startHandshake()
            return socket.session.peerCertificates.filterIsInstance<X509Certificate>()
        } finally {
            runCatching { socket.close() }
        }
    }
}
