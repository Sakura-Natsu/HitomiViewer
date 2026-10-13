import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// 一次即将发出的请求，可在 [RequestHook] 中修改（例如改走反向代理）。
class HitomiRequest {
  HitomiRequest({
    required this.host,
    required this.path,
    this.range,
    Map<String, String>? headers,
  }) : headers = headers ?? {};

  String host;

  /// 已经过百分号编码的路径，以 `/` 开头。
  String path;

  /// 形如 `0-99` 的字节范围，对应 `Range: bytes=0-99`。
  final String? range;

  final Map<String, String> headers;

  Uri get uri => Uri.parse('https://$host$path');
}

typedef RequestHook = FutureOr<void> Function(HitomiRequest request);

class HitomiResponse {
  HitomiResponse(this.statusCode, this.bytes, this.headers);

  final int statusCode;
  final Uint8List bytes;
  final Map<String, String> headers;

  ByteData get view => ByteData.sublistView(bytes);

  String get text => utf8.decode(bytes, allowMalformed: true);

  dynamic get json => jsonDecode(text);

  /// 从 `Content-Range: bytes 0-99/4885124` 中取出资源总字节数。
  int? get totalLength {
    final contentRange = headers['content-range'];
    if (contentRange == null) {
      return statusCode == 200 ? bytes.length : null;
    }
    final slash = contentRange.lastIndexOf('/');
    if (slash == -1) return null;
    return int.tryParse(contentRange.substring(slash + 1).trim());
  }
}
