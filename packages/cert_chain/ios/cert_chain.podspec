#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint cert_chain.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'cert_chain'
  s.version          = '0.0.1'
  s.summary          = 'Captures the TLS certificate chain a server presents.'
  s.description      = <<-DESC
Captures the TLS certificate chain (leaf plus intermediates) that a server
actually presents, which Dart's SecureSocket does not expose.
                       DESC
  s.homepage         = 'https://gitlab.com/ranjithraj/vigilant-core'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ranjith Raj' => 'ranjithraj@riseup.net' }
  s.source           = { :path => '.' }
  s.source_files = 'cert_chain/Sources/cert_chain/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # The manifest ships inside the plugin's SwiftPM target automatically, but the
  # CocoaPods path needs it declared explicitly or it never reaches the app bundle.
  # cert_chain only calls SecTrust* APIs, so the manifest declares no required
  # reason API usage; it is bundled so the plugin stays correct if that changes.
  s.resource_bundles = {'cert_chain_privacy' => ['cert_chain/Sources/cert_chain/PrivacyInfo.xcprivacy']}
end
