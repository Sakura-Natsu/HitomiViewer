import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'cached_value.dart';
import 'constants.dart';
import 'error.dart';
import 'gallery_manager.dart';
import 'index_provider.dart';
import 'models/media.dart';
import 'models/tag.dart';
import 'tag_manager.dart';
import 'transport.dart';

/// Hitomi.la 客户端，是 node-hitomi `Hitomi` 类的 Dart 移植。
class Hitomi {
  Hitomi({
    http.Client? client,
    this.onRequest,
    this.timeout = const Duration(seconds: 30),
    Duration indexMaxAge = const Duration(minutes: 10),
    Duration imageContextMaxAge = const Duration(hours: 1),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null {
    galleries = GalleryManager(this, indexMaxAge);
    tags = TagManager(this);
    languageIndex = IndexProvider(this, 'languages', indexMaxAge);
    _imageContext = CachedValue(_fetchImageContext, imageContextMaxAge);
    _languageSupport = CachedValue(_fetchLanguageSupport, indexMaxAge);
  }

  final http.Client _client;
  final bool _ownsClient;

  /// 每次请求前调用，可修改请求的 host、path 与请求头。
  final RequestHook? onRequest;

  /// 单次请求（包括读取响应体）的超时时间。
  final Duration timeout;

  late final GalleryManager galleries;
  late final TagManager tags;
  late final IndexProvider languageIndex;
  late final CachedValue<ImageContext> _imageContext;
  late final CachedValue<List<Language?>> _languageSupport;

  /// 发送 GET 请求。状态码不是 200/206 且不在 [allowStatus] 中时抛出 [HitomiException]。
  Future<HitomiResponse> request(
    String host,
    String path, {
    String? range,
    Set<int> allowStatus = const {},
  }) async {
    final request = HitomiRequest(
      host: host,
      path: path,
      range: range,
      headers: {
        ...defaultHeaders,
        // 范围请求必须禁用压缩，否则字节偏移会对应压缩后的内容。
        if (range != null) ...{
          'range': 'bytes=$range',
          'accept-encoding': 'identity',
        },
      },
    );
    await onRequest?.call(request);

    final uri = request.uri;
    final response = await () async {
      final streamed = await _client.send(
        http.Request('GET', uri)..headers.addAll(request.headers),
      );
      // 服务器忽略 Range 时会返回完整文件，索引文件有数 GB，不能整个读下来。
      final length = streamed.contentLength;
      if (range != null &&
          streamed.statusCode == 200 &&
          (length == null || length > _maxFullResponseForRange)) {
        unawaited(streamed.stream.listen(null).cancel());
        throw HitomiException(
          HitomiErrorCode.unexpectedResponseBody,
          '$uri ignored the Range header',
        );
      }
      return http.Response.fromStream(streamed);
    }().timeout(timeout);

    final status = response.statusCode;
    if (status != 200 && status != 206 && !allowStatus.contains(status)) {
      throw HitomiException.unexpectedStatus(uri, status);
    }
    return HitomiResponse(status, response.bodyBytes, response.headers);
  }

  /// 范围请求被忽略时，允许读取的完整响应上限（nozomi 文件一般只有几 MB）。
  static const int _maxFullResponseForRange = 64 << 20;

  /// 一次请求读取多个字节范围（HTTP multipart/byteranges），返回 起始偏移 → 数据。
  ///
  /// 缺少的范围不会出现在结果中。
  Future<Map<int, Uint8List>> requestRanges(
    String host,
    String path,
    List<(int, int)> ranges,
  ) async {
    if (ranges.isEmpty) return const {};
    final response = await request(
      host,
      path,
      range: [for (final (start, end) in ranges) '$start-$end'].join(','),
    );

    final contentType = response.headers['content-type'] ?? '';
    final boundary = RegExp(r'boundary=("?)([^";]+)\1')
        .firstMatch(contentType)
        ?.group(2);
    if (boundary != null && contentType.contains('multipart/byteranges')) {
      return parseMultipartByteRanges(response.bytes, boundary);
    }

    // 单个范围（或服务器合并了范围）：按 Content-Range 截取。
    var offset = 0;
    final contentRange = response.headers['content-range'];
    if (contentRange != null) {
      final match = RegExp(r'bytes\s+(\d+)-').firstMatch(contentRange);
      if (match != null) offset = int.parse(match.group(1)!);
    }
    final bytes = response.bytes;
    return {
      for (final (start, end) in ranges)
        if (start >= offset && end - offset < bytes.length)
          start: Uint8List.sublistView(bytes, start - offset, end - offset + 1),
    };
  }

  /// 解析 multipart/byteranges 响应体。按 Content-Range 的长度截取数据，
  /// 而不是搜索分隔符，因此二进制内容中出现分隔符也不会出错。
  static Map<int, Uint8List> parseMultipartByteRanges(
    Uint8List body,
    String boundary,
  ) {
    final result = <int, Uint8List>{};
    final delimiter = latin1.encode('--$boundary');
    const headerEnd = [13, 10, 13, 10];
    final contentRange = RegExp(
      r'content-range:\s*bytes\s+(\d+)-(\d+)',
      caseSensitive: false,
    );

    var position = 0;
    while (true) {
      final start = _indexOf(body, delimiter, position);
      if (start == -1) break;
      final afterDelimiter = start + delimiter.length;
      // `--boundary--` 表示结束
      if (afterDelimiter + 1 < body.length &&
          body[afterDelimiter] == 45 &&
          body[afterDelimiter + 1] == 45) {
        break;
      }
      final headersEnd = _indexOf(body, headerEnd, afterDelimiter);
      if (headersEnd == -1) break;
      final headers = latin1.decode(
        Uint8List.sublistView(body, afterDelimiter, headersEnd),
      );
      final dataStart = headersEnd + headerEnd.length;
      final match = contentRange.firstMatch(headers);
      if (match == null) {
        position = dataStart;
        continue;
      }
      final from = int.parse(match.group(1)!);
      final to = int.parse(match.group(2)!);
      final dataEnd = dataStart + to - from + 1;
      if (dataEnd > body.length) break;
      result[from] = Uint8List.sublistView(body, dataStart, dataEnd);
      position = dataEnd;
    }
    return result;
  }

  static int _indexOf(Uint8List data, List<int> pattern, int from) {
    final last = data.length - pattern.length;
    outer:
    for (var i = from; i <= last; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  /// 搜索词哈希：SHA-256 的前 4 个字节。
  Uint8List hashTerm(String text) =>
      Uint8List.fromList(sha256.convert(utf8.encode(text)).bytes.sublist(0, 4));

  /// 图片 URL 规则（gg.js），带缓存。
  Future<ImageContext> imageContext({bool forceRefresh = false}) =>
      _imageContext.get(forceRefresh: forceRefresh);

  Future<ImageContext> _fetchImageContext() async {
    final response = await request(resourceDomain, '/gg.js');
    return ImageContext.parse(response.text);
  }

  /// languages 索引的位编号 → 语言，来自 language_support.js，获取失败时使用内置列表。
  Future<List<Language?>> languageSupport() async {
    try {
      return await _languageSupport.get();
    } on Object {
      return Language.ordered;
    }
  }

  Future<List<Language?>> _fetchLanguageSupport() async {
    final response = await request(resourceDomain, '/language_support.js');
    return parseLanguageSupport(response.text);
  }

  /// 解析 language_support.js 中的 `bitnumber_language` 与 `language_localname`。
  static List<Language?> parseLanguageSupport(String source) {
    Map<String, dynamic>? object(String name) {
      final match = RegExp('$name\\s*=\\s*(\\{[^}]*\\})').firstMatch(source);
      if (match == null) return null;
      return jsonDecode(match.group(1)!) as Map<String, dynamic>;
    }

    final bits = object('bitnumber_language');
    if (bits == null || bits.isEmpty) {
      throw HitomiException(
        HitomiErrorCode.unexpectedResponseBody,
        'language_support.js is not parsable',
      );
    }
    final localNames = object('language_localname') ?? const {};

    final entries = <int, String>{
      for (final entry in bits.entries)
        if (int.tryParse(entry.key) case final int bit) bit: '${entry.value}',
    };
    final maxBit = entries.keys.reduce((a, b) => a > b ? a : b);
    return [
      for (var bit = 0; bit <= maxBit; bit++)
        if (entries[bit] case final String name)
          Language(
            name,
            localNames[name] as String? ??
                Language.byName(name)?.localName ??
                name,
          )
        else
          null,
    ];
  }

  /// 获取图片地址。缩略图不需要 gg.js，原图需要。
  Future<String> resolveImageUrl(
    GalleryImage image, {
    ImageExtension extension = ImageExtension.webp,
    ThumbnailSize? thumbnailSize,
  }) async {
    if (thumbnailSize != null) {
      return image.thumbnailUrl(extension: extension, size: thumbnailSize);
    }
    return image.fullUrl(await imageContext(), extension: extension);
  }

  /// 下载图片字节。
  Future<Uint8List> fetchImage(
    GalleryImage image, {
    ImageExtension extension = ImageExtension.webp,
    ThumbnailSize? thumbnailSize,
  }) async {
    final url = Uri.parse(
      await resolveImageUrl(
        image,
        extension: extension,
        thumbnailSize: thumbnailSize,
      ),
    );
    return (await request(url.host, url.path)).bytes;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
