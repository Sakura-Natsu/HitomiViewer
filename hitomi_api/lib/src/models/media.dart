import '../constants.dart';
import '../error.dart';

enum ImageExtension { avif, webp, jxl }

enum ThumbnailSize {
  small('small'),

  /// 仅 AVIF 可用。
  medium('smallbig'),
  big('big');

  const ThumbnailSize(this.pathName);

  final String pathName;
}

/// 对应 common.js 的 real_full_path_from_hash：`abc...xyz` → `z/xy`。
String hashPath(String hash, [String separator = '/']) {
  final length = hash.length;
  return '${hash.substring(length - 1)}$separator'
      '${hash.substring(length - 3, length - 1)}';
}

/// 对应 gg.js 的 `s(h)`：取哈希末三位重排后按十六进制解析。
int hashCodeOf(String hash) => int.parse(hashPath(hash, ''), radix: 16);

/// 从 gg.js 中解析出的图片 URL 规则。gg.js 会周期性变化，需定期刷新。
class ImageContext {
  const ImageContext({
    required this.codes,
    required this.defaultValue,
    required this.matchedValue,
    required this.pathPrefix,
  });

  /// gg.js 中 `switch` 的所有 case 值。
  final Set<int> codes;

  /// `var o = N;` 中的 N，即不在 case 列表中时 `gg.m` 的返回值。
  final int defaultValue;

  /// case 分支中 `o = N; break;` 的 N。
  final int matchedValue;

  /// `b: '1791885602/'`，图片路径前缀。
  final String pathPrefix;

  int m(int code) => codes.contains(code) ? matchedValue : defaultValue;

  static ImageContext parse(String source) {
    final codes = <int>{
      for (final match in RegExp(r'case\s+(\d+)\s*:').allMatches(source))
        int.parse(match.group(1)!),
    };
    if (codes.isEmpty) throw HitomiException.unparsableImageContext();

    final defaultMatch = RegExp(r'var\s+o\s*=\s*(\d+)\s*;').firstMatch(source);
    if (defaultMatch == null) throw HitomiException.unparsableImageContext();
    final defaultValue = int.parse(defaultMatch.group(1)!);

    final matchedMatch = RegExp(r'o\s*=\s*(\d+)\s*;\s*break\s*;')
        .firstMatch(source);
    final matchedValue = matchedMatch != null
        ? int.parse(matchedMatch.group(1)!)
        : (defaultValue == 0 ? 1 : 0);

    final prefixMatches = RegExp(r"""\bb\s*:\s*['"]([^'"]*)['"]""")
        .allMatches(source)
        .toList();
    if (prefixMatches.isEmpty) throw HitomiException.unparsableImageContext();
    final pathPrefix = prefixMatches.last.group(1)!;
    if (pathPrefix.isEmpty) throw HitomiException.unparsableImageContext();

    return ImageContext(
      codes: codes,
      defaultValue: defaultValue,
      matchedValue: matchedValue,
      pathPrefix: pathPrefix,
    );
  }
}

/// 画廊中的一张图片。
class GalleryImage {
  const GalleryImage({
    required this.hash,
    required this.name,
    required this.width,
    required this.height,
    this.hasAvif = false,
    this.hasWebp = true,
    this.hasJxl = false,
    this.hasThumbnail = false,
  });

  final String hash;

  /// 原始文件名，如 `01.png`。
  final String name;
  final int width;
  final int height;
  final bool hasAvif;
  final bool hasWebp;
  final bool hasJxl;

  /// 是否有 big / smallbig 尺寸的缩略图（仅首页与中间页有）。
  final bool hasThumbnail;

  double get aspectRatio => height == 0 ? 1 : width / height;

  bool supports(ImageExtension extension) => switch (extension) {
    ImageExtension.avif => hasAvif,
    ImageExtension.webp => hasWebp,
    ImageExtension.jxl => hasJxl,
  };

  void _checkExtension(ImageExtension extension) {
    if (!supports(extension)) {
      throw HitomiException(
        HitomiErrorCode.invalidCombination,
        'Extension ${extension.name} is not available for image $hash',
      );
    }
  }

  /// 缩略图地址。[ThumbnailSize.small] 对所有图片都可用。
  String thumbnailUrl({
    ImageExtension extension = ImageExtension.webp,
    ThumbnailSize size = ThumbnailSize.small,
  }) {
    _checkExtension(extension);
    if (size == ThumbnailSize.medium && extension != ImageExtension.avif) {
      throw HitomiException(
        HitomiErrorCode.invalidCombination,
        'ThumbnailSize.medium must be used only with avif',
      );
    }
    if (size != ThumbnailSize.small && !hasThumbnail) {
      throw HitomiException(
        HitomiErrorCode.invalidCombination,
        'ThumbnailSize.${size.name} must be used only with image that has thumbnail',
      );
    }
    return 'https://$thumbnailDomain/${extension.name}${size.pathName}tn/'
        '${hashPath(hash)}/$hash.${extension.name}';
  }

  /// 原图地址，规则见 common.js 的 url_from_url_from_hash / subdomain_from_url。
  String fullUrl(
    ImageContext context, {
    ImageExtension extension = ImageExtension.webp,
  }) {
    _checkExtension(extension);
    final code = hashCodeOf(hash);
    final subdomain = '${extension.name[0]}${1 + context.m(code)}';
    return 'https://$subdomain.$baseDomain/'
        '${context.pathPrefix}$code/$hash.${extension.name}';
  }

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'name': name,
    'width': width,
    'height': height,
    'hasavif': hasAvif ? 1 : 0,
  };
}

class Video {
  const Video({
    required this.fileName,
    required this.posterHash,
    required this.width,
    required this.height,
  });

  final String fileName;
  final String posterHash;
  final int width;
  final int height;

  String get url => 'https://streaming.$baseDomain/videos/$fileName';

  String get posterUrl =>
      'https://a.$baseDomain/videos/posters/${hashPath(posterHash)}/$posterHash.webp';
}
