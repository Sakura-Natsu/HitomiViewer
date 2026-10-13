import 'dart:io';

import 'package:hitomi_api/io.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

enum ProxyMode {
  /// Windows 读取系统代理设置，其他平台读取 HTTP_PROXY 等环境变量。
  system,
  direct,
  manual,
}

class ProxyConfig {
  const ProxyConfig({
    this.mode = ProxyMode.system,
    this.host = '',
    this.port = 0,
  });

  final ProxyMode mode;
  final String host;
  final int port;

  bool get isManualValid => host.isNotEmpty && port > 0 && port < 65536;
}

/// 可在运行时切换代理的 HTTP 客户端，切换时不影响已发出的请求。
class ProxyHttpClient extends http.BaseClient {
  ProxyHttpClient(ProxyConfig config) {
    final (client, description) = _create(config, null);
    _raw = client;
    _inner = IOClient(client);
    proxyDescription = description;
  }

  late HttpClient _raw;
  late http.Client _inner;

  /// 当前实际生效的代理描述，用于设置页展示。
  late String proxyDescription;

  void configure(ProxyConfig config, {String? systemProxy}) {
    final old = _raw;
    final (client, description) = _create(config, systemProxy);
    _raw = client;
    _inner = IOClient(client);
    proxyDescription = description;
    // 不能调用 IOClient.close()：它会 force 关闭，中断正在进行的请求。
    old.close();
  }

  static (HttpClient, String) _create(ProxyConfig config, String? systemProxy) {
    // 代理通过自建的 CONNECT 隧道实现（见 createProxyHttpClient）：
    // dart:io 自带的代理不会复用连接，每个请求都要重新握手。
    HttpClient tunnel(String host, int port) =>
        createProxyHttpClient(host, port);

    final (HttpClient client, String description) = switch (config.mode) {
      ProxyMode.direct => (HttpClient(), '直连'),
      ProxyMode.manual when config.isManualValid => (
        tunnel(config.host, config.port),
        'HTTP 代理 ${config.host}:${config.port}',
      ),
      ProxyMode.manual => (HttpClient(), '代理地址无效，已直连'),
      ProxyMode.system => switch (_parseHostPort(systemProxy) ??
          proxyFromEnvironment()) {
        (final host, final port) => (
          tunnel(host, port),
          '${systemProxy != null ? '系统代理' : '环境变量代理'} $host:$port',
        ),
        null => (HttpClient(), '未检测到系统代理，直连'),
      },
    };

    client
      ..connectionTimeout = const Duration(seconds: 15)
      // 服务器的 keep-alive 为 60 秒，空闲连接尽量多保留一会儿
      ..idleTimeout = const Duration(seconds: 55)
      ..maxConnectionsPerHost = 12;
    return (client, description);
  }

  static (String, int)? _parseHostPort(String? value) {
    if (value == null) return null;
    final colon = value.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(value.substring(colon + 1));
    if (port == null) return null;
    return (value.substring(0, colon), port);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => _inner.close();
}

/// 读取 Windows 的系统代理（Internet 选项 / Clash 等工具设置的代理）。
///
/// 返回 `host:port`，未启用时返回 null。
Future<String?> detectWindowsSystemProxy() async {
  if (!Platform.isWindows) return null;
  const key =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  try {
    final enable = await Process.run('reg', [
      'query',
      key,
      '/v',
      'ProxyEnable',
    ]);
    final enabled = RegExp(r'ProxyEnable\s+REG_DWORD\s+0x0*1\b')
        .hasMatch('${enable.stdout}');
    if (!enabled) return null;

    final server = await Process.run('reg', [
      'query',
      key,
      '/v',
      'ProxyServer',
    ]);
    final match = RegExp(r'ProxyServer\s+REG_SZ\s+(\S+)')
        .firstMatch('${server.stdout}');
    if (match == null) return null;
    return parseWindowsProxyServer(match.group(1)!);
  } on Object {
    return null;
  }
}

/// 解析 `127.0.0.1:7890` 或 `http=127.0.0.1:7890;https=127.0.0.1:7890` 格式。
String? parseWindowsProxyServer(String value) {
  final entries = value.split(';').where((e) => e.trim().isNotEmpty).toList();
  if (entries.isEmpty) return null;
  String? pick(String scheme) {
    for (final entry in entries) {
      if (entry.toLowerCase().startsWith('$scheme=')) {
        return entry.substring(scheme.length + 1);
      }
    }
    return null;
  }

  var proxy =
      pick('https') ??
      pick('http') ??
      (entries.first.contains('=') ? null : entries.first);
  if (proxy == null) return null;
  proxy = proxy.replaceFirst(RegExp(r'^https?://'), '');
  return proxy.contains(':') ? proxy : null;
}
