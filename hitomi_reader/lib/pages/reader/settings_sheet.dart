import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/app_services.dart';
import '../../services/settings.dart';

final bool _android = defaultTargetPlatform == TargetPlatform.android;

/// 阅读中可调整的设置。阅读方向由阅读页自己管理，其余直接写入 [AppSettings]。
Future<void> showReaderSettings(
  BuildContext context, {
  required ReaderMode Function() mode,
  required ValueChanged<ReaderMode> onModeChanged,
  required VoidCallback onShowGuide,
}) {
  final settings = services.settings;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    // 调亮度时能看清背后的页面
    barrierColor: Colors.black12,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (sheetContext, controller) => ListenableBuilder(
        listenable: settings,
        builder: (sheetContext, _) {
          final current = mode();
          final paged = current != ReaderMode.vertical;
          return ListView(
            controller: controller,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              const _Header('阅读方向'),
              _Segments<ReaderMode>(
                values: ReaderMode.values,
                selected: current,
                label: (mode) => mode.shortLabel,
                onChanged: onModeChanged,
              ),
              if (paged) ...[
                const _Header('每屏页数'),
                _Segments<PageLayout>(
                  values: PageLayout.values,
                  selected: settings.pageLayout,
                  label: (layout) => layout.label,
                  onChanged: (value) => settings.pageLayout = value,
                ),
                if (settings.pageLayout == PageLayout.auto)
                  const _Caption('自动：横屏时双页，竖屏时单页'),
                if (settings.pageLayout != PageLayout.single)
                  SwitchListTile(
                    title: const Text('封面单独显示'),
                    subtitle: const Text('让后面的跨页左右对齐'),
                    value: settings.coverAlone,
                    onChanged: (value) => settings.coverAlone = value,
                  ),
              ],
              const _Header('翻页'),
              SwitchListTile(
                title: const Text('点击屏幕两侧翻页'),
                subtitle: const Text('关闭后点击任意位置显示菜单'),
                value: settings.tapToTurn,
                onChanged: (value) => settings.tapToTurn = value,
              ),
              ListTile(
                title: const Text('查看点击区域'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onShowGuide();
                },
              ),
              if (paged)
                SwitchListTile(
                  title: const Text('翻页动画'),
                  subtitle: const Text('点击、按键翻页时滑动过渡'),
                  value: settings.pageAnimation,
                  onChanged: (value) => settings.pageAnimation = value,
                ),
              if (_android) ...[
                SwitchListTile(
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
                    title: const Text('反转音量键'),
                    value: settings.volumeKeysInverted,
                    onChanged: (value) => settings.volumeKeysInverted = value,
                  ),
              ],
              ListTile(
                title: Text('自动翻页间隔：${settings.autoTurnSeconds} 秒'),
                subtitle: Slider(
                  value: settings.autoTurnSeconds.toDouble(),
                  min: 1,
                  max: 30,
                  divisions: 29,
                  label: '${settings.autoTurnSeconds} 秒',
                  onChanged: (value) =>
                      settings.autoTurnSeconds = value.round(),
                ),
              ),
              const _Header('显示'),
              SwitchListTile(
                title: const Text('裁切白边'),
                subtitle: const Text('自动去掉页面四周的白边或黑边，图片显示得更大'),
                value: settings.cropBorders,
                onChanged: (value) => settings.cropBorders = value,
              ),
              SwitchListTile(
                title: const Text('屏幕常亮'),
                value: settings.keepScreenOn,
                onChanged: (value) => settings.keepScreenOn = value,
              ),
              SwitchListTile(
                title: const Text('显示页码、时间和电量'),
                value: settings.readerInfo,
                onChanged: (value) => settings.readerInfo = value,
              ),
              ListTile(
                title: Text(
                  settings.readerDim == 0
                      ? '降低亮度：关闭'
                      : '降低亮度：${settings.readerDim}%',
                ),
                subtitle: Slider(
                  value: settings.readerDim.toDouble(),
                  max: 80,
                  divisions: 16,
                  label: '${settings.readerDim}%',
                  onChanged: (value) => settings.readerDim = value.round(),
                ),
              ),
              if (_android) ...[
                const _Header('屏幕方向'),
                _Segments<ReaderOrientation>(
                  values: ReaderOrientation.values,
                  selected: settings.readerOrientation,
                  label: (orientation) => orientation.label,
                  onChanged: (value) => settings.readerOrientation = value,
                ),
              ],
              const _Header('加载'),
              ListTile(
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
            ],
          );
        },
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

class _Segments<T> extends StatelessWidget {
  const _Segments({
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: SegmentedButton<T>(
      showSelectedIcon: false,
      segments: [
        for (final value in values)
          ButtonSegment(value: value, label: Text(label(value))),
      ],
      selected: {selected},
      onSelectionChanged: (selection) => onChanged(selection.first),
    ),
  );
}
