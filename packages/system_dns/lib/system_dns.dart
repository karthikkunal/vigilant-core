/// Resolves DNS through the platform's own resolver where that is possible.
library;

export 'src/system_dns_client.dart' show SystemDnsClient;
export 'system_dns_method_channel.dart' show MethodChannelSystemDns;
export 'system_dns_platform_interface.dart' show SystemDnsPlatform;
