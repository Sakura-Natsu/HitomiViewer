import 'package:flutter/widgets.dart';
import 'package:hitomi_api/hitomi_api.dart';

import 'settings.dart';
import 'tag_translations.dart';

/// 标签的显示名称：开启翻译且标签库中有该标签时显示中文。
///
/// 同时监听标签库与设置，只在实际显示效果可能变化时通知。
class TagLabels extends ChangeNotifier {
  TagLabels(this._settings, this.translations) {
    _enabled = _settings.tagTranslation;
    _settings.addListener(_onSettingsChanged);
    translations.addListener(notifyListeners);
  }

  final AppSettings _settings;
  final TagTranslations translations;
  late bool _enabled;

  bool get enabled => _enabled && translations.isLoaded;

  void _onSettingsChanged() {
    if (_settings.tagTranslation == _enabled) return;
    _enabled = _settings.tagTranslation;
    notifyListeners();
  }

  /// 中文名，没有翻译或未开启时返回 null。
  String? chinese(Tag tag) => enabled ? translations.lookup(tag)?.name : null;

  /// 标签释义（不受开关影响，长按标签时显示）。
  TagInfo? info(Tag tag) => translations.lookup(tag);

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    translations.removeListener(notifyListeners);
    super.dispose();
  }
}

/// 让依赖标签名称的组件在标签库加载、更新或开关切换时自动重建。
class TagLabelScope extends InheritedNotifier<TagLabels> {
  const TagLabelScope({
    super.key,
    required TagLabels labels,
    required super.child,
  }) : super(notifier: labels);

  static TagLabels of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TagLabelScope>()!.notifier!;
}
