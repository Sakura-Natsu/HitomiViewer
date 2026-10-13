/// 基于 dart:io 的辅助工具（不能用于 Web）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 创建经 HTTP 代理访问的 [HttpClient]，并能正常复用连接。
///
/// dart:io 自带的代理支持（`findProxy` 返回 `PROXY host:port`）有缺陷：
/// HTTPS 隧道建立后被登记在目标主机下，而查找空闲连接时用的是代理地址，
/// 导致每个请求都重新建立 TLS 连接（实测每次多约 0.6 秒），
/// 设置 `maxConnectionsPerHost` 时还会因计数错误而卡住。
///
/// 这里改为在 [HttpClient.connectionFactory] 中自己发送 `CONNECT` 并完成 TLS 握手，
/// 对 HttpClient 来说就是一条到目标主机的直连，连接池按目标主机复用。
HttpClient createProxyHttpClient(
  String proxyHost,
  int proxyPort, {
  Duration connectTimeout = const Duration(seconds: 15),
}) {
  return HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, _, _) =>
        connectThroughProxy(uri, proxyHost, proxyPort, timeout: connectTimeout);
}

/// 根据 `HTTPS_PROXY` / `HTTP_PROXY` 等环境变量创建客户端，没有代理时直连。
HttpClient createEnvironmentHttpClient() {
  final proxy = proxyFromEnvironment();
  if (proxy == null) return HttpClient();
  return createProxyHttpClient(proxy.$1, proxy.$2);
}

/// 从环境变量读取代理，返回 (host, port)。
(String, int)? proxyFromEnvironment() {
  final env = Platform.environment;
  final value =
      env['https_proxy'] ??
      env['HTTPS_PROXY'] ??
      env['http_proxy'] ??
      env['HTTP_PROXY'];
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  if (uri == null || uri.host.isEmpty) return null;
  return (uri.host, uri.hasPort ? uri.port : 80);
}

/// 通过 HTTP 代理的 CONNECT 方法建立到 [uri] 的连接，https 时完成 TLS 握手。
Future<ConnectionTask<Socket>> connectThroughProxy(
  Uri uri,
  String proxyHost,
  int proxyPort, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final task = await Socket.startConnect(proxyHost, proxyPort);

  Future<Socket> establish() async {
    final socket = await task.socket;
    try {
      final isSecure = uri.scheme == 'https';
      final port = uri.hasPort ? uri.port : (isSecure ? 443 : 80);
      final authority = '${uri.host}:$port';
      socket.write(
        'CONNECT $authority HTTP/1.1\r\n'
        'Host: $authority\r\n'
        'Proxy-Connection: keep-alive\r\n\r\n',
      );

      // 读取代理的响应头。TLS 握手要等我们先发送 ClientHello，
      // 所以响应头之后不会有多余的数据。
      final header = Completer<String>();
      final buffer = BytesBuilder(copy: false);
      socket.listen(
        (data) {
          if (header.isCompleted) return;
          buffer.add(data);
          final text = latin1.decode(buffer.toBytes());
          if (text.contains('\r\n\r\n')) header.complete(text);
        },
        onError: (Object error) {
          if (!header.isCompleted) header.completeError(error);
        },
        onDone: () {
          if (!header.isCompleted) {
            header.completeError(
              const SocketException('Proxy closed the connection'),
            );
          }
        },
      );
      final response = await header.future.timeout(timeout);
      final statusLine = response.substring(0, response.indexOf('\r\n'));
      final status = int.tryParse(
        statusLine.split(' ').elementAtOrNull(1) ?? '',
      );
      if (status != 200) {
        throw SocketException('Proxy refused CONNECT: $statusLine');
      }

      if (!isSecure) return socket;
      return await SecureSocket.secure(socket, host: uri.host).timeout(timeout);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  return ConnectionTask.fromSocket(establish(), task.cancel);
}
