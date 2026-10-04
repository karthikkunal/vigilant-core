import Flutter
import Foundation
import Security

/// Captures the TLS certificate chain a server presents.
///
/// Uses a URLSession authentication challenge to read the server trust, then
/// returns each certificate as base64 DER. Parsing happens in Dart, so this
/// file stays free of X.509 parsing.
public class CertChainPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "cert_chain",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(CertChainPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "fetch" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let host = arguments["host"] as? String,
      !host.isEmpty
    else {
      result(FlutterError(code: "bad_args", message: "host is required", details: nil))
      return
    }

    let port = arguments["port"] as? Int ?? 443
    let timeoutMs = arguments["timeoutMs"] as? Int ?? 15000

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let payload = try self.capture(host: host, port: port, timeoutMs: timeoutMs)
        DispatchQueue.main.async { result(payload) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "tls_error",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  private func capture(host: String, port: Int, timeoutMs: Int) throws -> [String: Any] {
    let semaphore = DispatchSemaphore(value: 0)
    let delegate = TrustCapturingDelegate(semaphore: semaphore)

    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.port = port
    guard let url = components.url else {
      throw NSError(
        domain: "cert_chain",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not build a URL for \(host)"]
      )
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = TimeInterval(timeoutMs) / 1000.0
    let session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: nil
    )
    session.dataTask(with: url).resume()

    let deadline = DispatchTime.now() + .milliseconds(timeoutMs + 1500)
    _ = semaphore.wait(timeout: deadline)
    session.invalidateAndCancel()

    guard !delegate.certificates.isEmpty else {
      throw NSError(
        domain: "cert_chain",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The server presented no certificates."]
      )
    }

    let encoded: [String] = delegate.certificates.compactMap { certificate in
      SecCertificateCopyData(certificate) as Data?
    }.map { $0.base64EncodedString() }

    return ["trusted": delegate.trusted, "certs": encoded]
  }
}

/// Reads the server trust from the authentication challenge.
private final class TrustCapturingDelegate: NSObject, URLSessionDelegate {
  private let semaphore: DispatchSemaphore
  private var handled = false
  private(set) var certificates: [SecCertificate] = []
  private(set) var trusted = false

  init(semaphore: DispatchSemaphore) {
    self.semaphore = semaphore
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard !handled else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    handled = true

    if let trust = challenge.protectionSpace.serverTrust {
      var error: CFError?
      trusted = SecTrustEvaluateWithError(trust, &error)
      certificates = Self.copyChain(from: trust)
    }

    completionHandler(.cancelAuthenticationChallenge, nil)
    semaphore.signal()
  }

  private static func copyChain(from trust: SecTrust) -> [SecCertificate] {
    if #available(iOS 15.0, macOS 12.0, *) {
      return (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    }
    let count = SecTrustGetCertificateCount(trust)
    var chain: [SecCertificate] = []
    for index in 0..<count {
      if let certificate = SecTrustGetCertificateAtIndex(trust, index) {
        chain.append(certificate)
      }
    }
    return chain
  }
}
