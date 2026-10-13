/// 图片、索引等资源所在的根域名。
const String baseDomain = 'gold-usergeneratedcontent.net';

/// 索引、画廊 JSON、gg.js 等资源域名。
const String resourceDomain = 'ltn.$baseDomain';

/// 网站前端域名。
const String frontDomain = 'hitomi.la';

/// 标签联想索引域名。
const String tagIndexDomain = 'tagindex.$frontDomain';

/// 缩略图域名。
const String thumbnailDomain = 'tn.$baseDomain';

/// 图片服务器会校验 Referer，缺失时返回 404。
const String defaultReferer = 'https://$frontDomain/';

const String defaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

/// 请求 hitomi 资源时需要附带的请求头。
const Map<String, String> defaultHeaders = {
  'referer': defaultReferer,
  'user-agent': defaultUserAgent,
};

/// B 树索引中单个节点的最大字节数（对应 search.js 的 max_node_size）。
const int maxIndexNodeSize = 464;
