import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../navigation.dart';
import '../services/app_services.dart';
import '../services/http_client.dart';
import '../services/settings.dart';
import '../services/tag_translations.dart';
import '../utils/labels.dart';
import '../widgets/common.dart';
import '../widgets/home_drawer.dart';
import '../widgets/tag_suggestions.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<int>? _cacheSize;
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _cacheSize = services.images.cacheSize();
  }

  Future<T?> _choose<T>(
    String title,
    List<T> values,
    T current,
    String Function(T) label,
  ) {
    return showDialog<T>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          RadioGroup<T>(
            groupValue: current,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final value in values)
                  RadioListTile<T>(value: value, title: Text(label(value))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editProxy() async {
    final settings = services.settings;
    final current = settings.proxy;
    final host = TextEditingController(text: current.host);
    final port = TextEditingController(
      text: current.port == 0 ? '' : '${current.port}',
    );
    final result = await showDialog<ProxyConfig>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('HTTP 代理'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: host,
              decoration: const InputDecoration(
                labelText: '主机',
                hintText: '127.0.0.1',
              ),
            ),
            TextField(
              controller: port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '端口',
                hintText: '7890',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '仅支持 HTTP 代理（Clash、v2rayN 等软件的“HTTP 端口”或“混合端口”）。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              ProxyConfig(
                mode: ProxyMode.manual,
                host: host.text.trim(),
                port: int.tryParse(port.text.trim()) ?? 0,
              ),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    host.dispose();
    port.dispose();
    if (result != null) {
      await settings.setProxy(result);
      await services.applyProxy();
      if (mounted) setState(() => _testResult = null);
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final watch = Stopwatch()..start();
    try {
      await services.hitomi.imageContext(forceRefresh: true);
      await services.hitomi.galleries.listPage(page: 0, pageSize: 1);
      _testResult = '连接成功（${watch.elapsedMilliseconds} ms）';
    } catch (error) {
      _testResult = '连接失败：${describeError(error)}';
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _clearCache() async {
    await services.images.clearCache();
    PaintingBinding.instance.imageCache.clear();
    if (!mounted) return;
    setState(() => _cacheSize = services.images.cacheSize());
    showMessage(context, '缓存已清除');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: drawerMenuButton(context),
        title: const Text('设置'),
      ),
      body: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final settings = services.settings;
          final proxy = settings.proxy;
          return ListView(
            children: [
              const _Section('浏览'),
              ListTile(
                leading: const Icon(Icons.translate),
                title: const Text('默认语言'),
                subtitle: Text(languageOptionLabel(settings.language)),
                onTap: () async {
                  final value = await _choose(
                    '默认语言',
                    languageOptions,
                    settings.language,
                    languageOptionLabel,
                  );
                  if (value != null) settings.language = value;
                },
              ),
              ListTile(
                leading: const Icon(Icons.sort),
                title: const Text('默认排序'),
                subtitle: Text(sortLabel(settings.defaultSort)),
                onTap: () async {
                  final value = await _choose(
                    '默认排序',
                    SortType.values,
                    settings.defaultSort,
                    sortLabel,
                  );
                  if (value != null) settings.defaultSort = value;
                },
              ),
              ListTile(
                leading: const Icon(Icons.view_agenda_outlined),
                title: const Text('列表样式'),
                subtitle: Text(
                  settings.listStyle == ListStyle.list ? '列表' : '网格',
                ),
                onTap: () =>
                    settings.listStyle = settings.listStyle == ListStyle.list
                    ? ListStyle.grid
                    : ListStyle.list,
              ),
              ListTile(
                leading: const Icon(Icons.block),
                title: const Text('屏蔽标签'),
                subtitle: Text(
                  settings.blockedTags.isEmpty
                      ? '未设置'
                      : '${settings.blockedTags.length} 个：${settings.blockedTags.take(3).join(' ')}',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BlockedTagsPage()),
                ),
              ),
              const _Section('标签翻译'),
              SwitchListTile(
                secondary: const Icon(Icons.translate),
                title: const Text('用中文显示标签'),
                subtitle: const Text('关闭后显示英文原名；中文联想搜索不受影响'),
                value: settings.tagTranslation,
                onChanged: (value) {
                  settings.tagTranslation = value;
                  if (value) services.translations.updateIfStale().ignore();
                },
              ),
              ListenableBuilder(
                listenable: services.translations,
                builder: (context, _) {
                  final translations = services.translations;
                  final String status;
                  if (translations.isUpdating) {
                    status = '正在下载…';
                  } else if (translations.isLoaded) {
                    status =
                        '${formatCount(translations.count)} 条，'
                        '更新于 ${formatDateTime(translations.updatedAt ?? DateTime.now())}';
                  } else if (translations.lastError != null) {
                    status = '下载失败：${describeError(translations.lastError!)}';
                  } else {
                    status = '尚未下载';
                  }
                  return ListTile(
                    leading: const Icon(Icons.library_books_outlined),
                    title: const Text('中文标签库'),
                    subtitle: Text(status),
                    trailing: translations.isUpdating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : TextButton(
                            onPressed: () async {
                              final changed = await translations.update();
                              if (!context.mounted) return;
                              showMessage(
                                context,
                                translations.lastError != null
                                    ? '更新失败'
                                    : changed
                                    ? '已更新'
                                    : '已是最新版本',
                              );
                            },
                            child: const Text('检查更新'),
                          ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('翻译来源'),
                subtitle: Text(
                  '${TagTranslations.sourceName} 项目（${TagTranslations.licenseName}，'
                  '仅限非商业使用），每天自动检查更新',
                ),
                onTap: () => openInBrowser(context, TagTranslations.sourceUrl),
              ),
              const _Section('阅读'),
              ListTile(
                leading: const Icon(Icons.chrome_reader_mode_outlined),
                title: const Text('阅读模式'),
                subtitle: Text(settings.readerMode.label),
                onTap: () async {
                  final value = await _choose(
                    '阅读模式',
                    ReaderMode.values,
                    settings.readerMode,
                    (mode) => mode.label,
                  );
                  if (value != null) settings.readerMode = value;
                },
              ),
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('每屏页数'),
                subtitle: Text(switch (settings.pageLayout) {
                  PageLayout.auto => '自动（横屏时双页）',
                  final layout => layout.label,
                }),
                onTap: () async {
                  final value = await _choose(
                    '每屏页数（翻页模式）',
                    PageLayout.values,
                    settings.pageLayout,
                    (layout) => switch (layout) {
                      PageLayout.auto => '自动（横屏时双页，竖屏时单页）',
                      _ => layout.label,
                    },
                  );
                  if (value != null) settings.pageLayout = value;
                },
              ),
              if (settings.pageLayout != PageLayout.single)
                SwitchListTile(
                  secondary: const Icon(Icons.auto_stories_outlined),
                  title: const Text('双页时封面单独显示'),
                  subtitle: const Text('让后面的跨页左右对齐'),
                  value: settings.coverAlone,
                  onChanged: (value) => settings.coverAlone = value,
                ),
              SwitchListTile(
                secondary: const Icon(Icons.touch_app_outlined),
                title: const Text('点击屏幕两侧翻页'),
                subtitle: const Text('关闭后点击任意位置显示菜单'),
                value: settings.tapToTurn,
                onChanged: (value) => settings.tapToTurn = value,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.animation),
                title: const Text('翻页动画'),
                subtitle: const Text('点击、按键翻页时滑动过渡'),
                value: settings.pageAnimation,
                onChanged: (value) => settings.pageAnimation = value,
              ),
              if (defaultTargetPlatform == TargetPlatform.android) ...[
                SwitchListTile(
                  secondary: const Icon(Icons.volume_down_outlined),
                  title: const Text('音量键翻页'),
                  subtitle: Text(
                    settings.volumeKeysInverted
                        ? '音量加：下一页，音量减：上一页'
                        : '音量减：下一页，音量加：上一页',
                  ),
                  value: settings.volumeKeys,
                  onChanged: (value) => settings.volumeKeys = value,
                ),
                if (settings.volumeKeys)
                  SwitchListTile(
                    secondary: const Icon(Icons.swap_vert),
                    title: const Text('反转音量键'),
                    value: settings.volumeKeysInverted,
                    onChanged: (value) => settings.volumeKeysInverted = value,
                  ),
              ],
              SwitchListTile(
                secondary: const Icon(Icons.crop),
                title: const Text('裁切白边'),
                subtitle: const Text('阅读时自动去掉页面四周的白边或黑边'),
                value: settings.cropBorders,
                onChanged: (value) => settings.cropBorders = value,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.light_mode_outlined),
                title: const Text('阅读时屏幕常亮'),
                value: settings.keepScreenOn,
                onChanged: (value) => settings.keepScreenOn = value,
              ),
              ListTile(
                leading: const Icon(Icons.fast_forward_outlined),
                title: Text('预加载页数：${settings.preloadPages}'),
                subtitle: Slider(
                  value: settings.preloadPages.toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  label: '${settings.preloadPages}',
                  onChanged: (value) => settings.preloadPages = value.round(),
                ),
              ),
              const _Section('网络'),
              ListTile(
                leading: const Icon(Icons.vpn_lock_outlined),
                title: const Text('代理'),
                subtitle: Text(services.http.proxyDescription),
                onTap: () async {
                  final mode = await _choose<ProxyMode>(
                    '代理模式',
                    ProxyMode.values,
                    proxy.mode,
                    (mode) => switch (mode) {
                      ProxyMode.system => '系统代理 / 环境变量',
                      ProxyMode.direct => '不使用代理',
                      ProxyMode.manual => '手动设置 HTTP 代理',
                    },
                  );
                  if (mode == null) return;
                  if (mode == ProxyMode.manual) {
                    await _editProxy();
                  } else {
                    await settings.setProxy(
                      ProxyConfig(
                        mode: mode,
                        host: proxy.host,
                        port: proxy.port,
                      ),
                    );
                    await services.applyProxy();
                    if (mounted) setState(() => _testResult = null);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.network_check),
                title: const Text('测试连接'),
                subtitle: _testResult == null ? null : Text(_testResult!),
                trailing: _testing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _testing ? null : _testConnection,
              ),
              const _Section('存储'),
              FutureBuilder<int>(
                future: _cacheSize,
                builder: (context, snapshot) => ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('清除图片缓存'),
                  subtitle: Text(
                    snapshot.hasData ? formatBytes(snapshot.data!) : '计算中…',
                  ),
                  onTap: _clearCache,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('缓存上限'),
                subtitle: Text(formatBytes(settings.cacheLimitMb << 20)),
                onTap: () async {
                  final value = await _choose(
                    '缓存上限',
                    const [256, 512, 1024, 2048, 4096],
                    settings.cacheLimitMb,
                    (mb) => formatBytes(mb << 20),
                  );
                  if (value != null) {
                    settings.cacheLimitMb = value;
                    await services.images.trimCache(value << 20);
                    if (mounted) {
                      setState(() => _cacheSize = services.images.cacheSize());
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('下载目录'),
                subtitle: Text(services.downloads.root.path),
                onTap: () =>
                    copyText(context, services.downloads.root.path, '路径'),
              ),
              const _Section('外观'),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('主题'),
                subtitle: Text(_themeLabel(settings.themeMode)),
                onTap: () async {
                  final value = await _choose(
                    '主题',
                    ThemeMode.values,
                    settings.themeMode,
                    _themeLabel,
                  );
                  if (value != null) settings.themeMode = value;
                },
              ),
              const _Section('关于'),
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/icon.png', width: 32, height: 32),
                ),
                title: const Text('HitomiViewer'),
                subtitle: const Text('非官方第三方客户端，内容均来自 hitomi.la'),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'HitomiViewer',
                  applicationIcon: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.asset(
                      'assets/icon.png',
                      width: 64,
                      height: 64,
                    ),
                  ),
                  applicationLegalese: '协议实现参考 node-hitomi（MIT License, Copyright (c) 2021 H2Owater425）。',
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  static String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 管理屏蔽标签。输入时与搜索页相同的标签联想（支持中文），点选即可屏蔽。
class BlockedTagsPage extends StatefulWidget {
  const BlockedTagsPage({super.key});

  @override
  State<BlockedTagsPage> createState() => _BlockedTagsPageState();
}

class _BlockedTagsPageState extends State<BlockedTagsPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final TagSuggestionController _suggestions = TagSuggestionController();

  @override
  void initState() {
    super.initState();
    _input.addListener(_onChanged);
    _suggestions.addListener(_refresh);
  }

  @override
  void dispose() {
    _suggestions.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String get _beforeCursor {
    final text = _input.text;
    final offset = _input.selection.baseOffset;
    return offset < 0 || offset > text.length
        ? text
        : text.substring(0, offset);
  }

  void _onChanged() {
    final composing = _input.value.composing;
    if (_input.text.trim().isEmpty) {
      _suggestions.clear();
    } else if (!composing.isValid || composing.isCollapsed) {
      // 输入法组字中（拼音还没上屏）先不查询
      _suggestions.update(_beforeCursor);
    }
    setState(() {});
  }

  void _block(Iterable<Tag> tags) {
    final blocked = services.settings.blockedTags;
    final added = [
      for (final tag in tags)
        if (!blocked.contains('${tag.negate(false)}')) tag.negate(false),
    ];
    if (added.isNotEmpty) {
      services.settings.blockedTags = [
        ...blocked,
        for (final tag in added) '$tag',
      ];
    }
    _input.clear();
    _suggestions.clear();
    showMessage(
      context,
      added.isEmpty
          ? '已经屏蔽过了'
          : '已屏蔽 ${added.map((tag) => tagFullName(context, tag)).join('、')}',
    );
  }

  /// 回车：输入的是 `类型:名称` 写法时直接屏蔽。
  void _submit() {
    final tags = services.hitomi.tags.parse(_input.text);
    if (tags.isNotEmpty) {
      _block(tags);
    } else {
      showMessage(context, '请从联想中点选标签，或输入 类型:名称，如 male:yaoi');
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('屏蔽标签')),
      body: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final blocked = services.settings.blockedTags;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: '输入要屏蔽的标签名，中英文均可',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _input.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除',
                            icon: const Icon(Icons.clear),
                            onPressed: _input.clear,
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              // 始终占位，加载状态变化时输入框下方的布局不跳动
              SizedBox(
                height: 2,
                child: _suggestions.loading
                    ? const LinearProgressIndicator(minHeight: 2)
                    : null,
              ),
              Expanded(
                child: _input.text.trim().isEmpty
                    ? _blockedList(theme, blocked)
                    : _candidateList(theme, blocked),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _blockedList(ThemeData theme, List<String> blocked) {
    final hint = tagTranslationHint();
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            ['含有这些标签的画廊会在列表中隐藏。也可以在画廊详情页长按标签快速屏蔽。', ?hint].join('\n'),
            style: TextStyle(color: theme.colorScheme.outline, fontSize: 12),
          ),
        ),
        if (blocked.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: EmptyView(message: '没有屏蔽的标签', icon: Icons.block),
          ),
        for (final raw in blocked)
          ListTile(
            title: Text(
              services.hitomi.tags
                  .parse(raw)
                  .map((tag) => tagFullName(context, tag))
                  .join('、'),
            ),
            subtitle: Text(raw),
            trailing: IconButton(
              tooltip: '取消屏蔽',
              icon: const Icon(Icons.close),
              onPressed: () => services.settings.blockedTags = blocked
                  .where((t) => t != raw)
                  .toList(),
            ),
          ),
      ],
    );
  }

  Widget _candidateList(ThemeData theme, List<String> blocked) {
    final typed = services.hitomi.tags.parse(_input.text);
    final candidates = _suggestions.candidates;
    final hint = tagTranslationHint();
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (typed.isNotEmpty)
          ListTile(
            leading: Icon(Icons.block, color: theme.colorScheme.error),
            title: Text(
              '屏蔽 ${typed.map((tag) => tagFullName(context, tag)).join('、')}',
            ),
            subtitle: Text(
              typed.map((tag) => '${tag.negate(false)}').join(' '),
            ),
            onTap: () => _block(typed),
          ),
        for (final candidate in candidates)
          TagCandidateTile(
            key: ValueKey('block-candidate:${candidate.tag.negate(false)}'),
            candidate: candidate,
            status: blocked.contains('${candidate.tag.negate(false)}')
                ? '已屏蔽'
                : null,
            onTap: () => _block([candidate.tag]),
            trailing: IconButton(
              tooltip: '屏蔽',
              icon: const Icon(Icons.block),
              onPressed: () => _block([candidate.tag]),
            ),
          ),
        if (candidates.isEmpty &&
            typed.isEmpty &&
            !_suggestions.loading &&
            _suggestions.query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '没有匹配的标签',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              hint,
              style: TextStyle(color: theme.colorScheme.outline, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
