import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../services/app_services.dart';
import '../services/crop.dart';
import '../services/device.dart';
import '../services/image_loader.dart';
import '../services/settings.dart';
import '../widgets/hitomi_image.dart';
import 'reader/page_image.dart';
import 'reader/settings_sheet.dart';
import 'reader/spreads.dart';
import 'reader/tap_guide.dart';
import 'reader/thumbnail_sheet.dart';
import 'reader/zoom.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.gallery, this.initialPage = 0});

  final Gallery gallery;
  final int initialPage;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final AppSettings _settings = services.settings;
  late ReaderMode _mode = _settings.readerMode;
  late int _page;
  bool _showUi = false;
  late bool _showGuide = !_settings.readerGuideShown;

  /// 正在拖动进度条时显示的页码。
  int? _sliderPage;
  bool _zoomed = false;
  final FocusNode _focus = FocusNode();

  /// 阅读器内容（深色主题）中的位置，弹出的面板用它取主题，与阅读器保持一致。
  final GlobalKey _themedKey = GlobalKey();

  BuildContext get _themedContext => _themedKey.currentContext ?? context;

  // 翻页模式：PageView 的每一项是一屏（单页或双页）。
  PageController? _pageController;
  ReaderSpreads? _spreads;

  /// 生成 [_spreads] 时的（是否双页，封面是否单独显示）。
  (bool, bool)? _spreadsKey;

  /// 正在动画翻向的那一屏，连续点击时从这里继续往后翻。
  int? _animatingTo;

  // 竖向模式
  ScrollController? _scrollController;
  final TransformationController _verticalTransform =
      TransformationController();

  /// 竖向模式下每页的起始偏移，最后一项为总高度。
  List<double> _offsets = const [];
  double _layoutWidth = 0;

  /// 白边检测结果变化后需要重新计算竖向模式的页面高度。
  bool _offsetsDirty = false;
  late bool _cropApplied = _settings.cropBorders;

  /// 状态栏与导航栏的高度。菜单的上下栏始终预留这么多空间，
  /// 状态栏出现或消失时菜单和画面都不需要重新布局。跨阅读页保留。
  static double _statusBarHeight = 0;
  static double _navigationBarHeight = 0;

  /// 每页的重试次数，变化后会生成新的图片缓存键。
  final Map<int, int> _attempts = {};

  bool _autoTurning = false;
  Timer? _autoTimer;

  Timer? _clockTimer;
  DateTime _now = DateTime.now();
  BatteryState? _battery;
  late bool _infoShown = _settings.readerInfo;

  DateTime _lastEndHint = DateTime(0);
  DateTime _lastWheel = DateTime(0);

  // 已经应用到系统的设置，变化时才调用平台接口。
  bool _screenKeptOn = false;
  ReaderOrientation _orientation = ReaderOrientation.auto;

  List<GalleryImage> get _files => widget.gallery.files;

  bool get _vertical => _mode == ReaderMode.vertical;

  bool get _double => !_vertical && (_spreadsKey?.$1 ?? false);

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage.clamp(0, max(0, _files.length - 1));
    services.library.recordRead(widget.gallery, _page);
    _applySystemBars();
    _settings.addListener(_onSettingsChanged);
    services.crops.addListener(_onCropsChanged);
    _applySystemSettings();
    _clockTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _updateClock(),
    );
    _updateClock();
    WidgetsBinding.instance.addPostFrameCallback((_) => _preload());
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    services.crops.removeListener(_onCropsChanged);
    _autoTimer?.cancel();
    _clockTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (_screenKeptOn) Device.keepScreenOn(false);
    if (_orientation != ReaderOrientation.auto) {
      SystemChrome.setPreferredOrientations(const []);
    }
    services.library.recordRead(widget.gallery, _page);
    _pageController?.dispose();
    _scrollController?.dispose();
    _verticalTransform.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    _applySystemSettings();
    // 刚打开页码显示时立即刷新时间和电量（拖动亮度滑块等不必每次都读电量）
    final info = _settings.readerInfo;
    if (info && !_infoShown) _updateClock();
    _infoShown = info;
    if (_settings.cropBorders != _cropApplied) {
      _cropApplied = _settings.cropBorders;
      _offsetsDirty = true;
    }
    setState(() {});
  }

  /// 竖向模式的页面高度取决于白边检测结果，检测完成后重新排版。
  void _onCropsChanged() {
    if (!_cropApplied || !_vertical || !mounted) return;
    _offsetsDirty = true;
    setState(() {});
  }

  void _applySystemSettings() {
    final keepOn = _settings.keepScreenOn;
    if (keepOn != _screenKeptOn) {
      _screenKeptOn = keepOn;
      Device.keepScreenOn(keepOn);
    }
    final orientation = _settings.readerOrientation;
    if (!isDesktop && orientation != _orientation) {
      _orientation = orientation;
      SystemChrome.setPreferredOrientations(switch (orientation) {
        ReaderOrientation.auto => const [],
        ReaderOrientation.portrait => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
        ReaderOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      });
    }
  }

  Future<void> _updateClock() async {
    if (!_settings.readerInfo) return;
    final battery = await Device.battery();
    if (!mounted) return;
    setState(() {
      _now = DateTime.now();
      _battery = battery;
    });
  }

  String? _local(int index) =>
      services.downloads.localPage(widget.gallery.id, index);

  /// 按屏幕尺寸解码，避免原图（常见 2560px 宽）占用过多内存。
  int get _decodeWidth {
    final size = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final width = _vertical
        ? min(size.width, _settings.verticalWidth.toDouble())
        : max(_double ? size.width / 2 : size.width, size.height * 0.75);
    // 取整到 256 像素，窗口或图片宽度小幅变化时可以复用已解码的图片
    return ((width * ratio) / 256).ceil() * 256;
  }

  ImageProvider _provider(int index) => HitomiImage.provider(
    _files[index],
    ImageKind.full,
    localFile: _local(index),
    decodeWidth: _decodeWidth,
    attempt: _attempts[index] ?? 0,
    detectCrop: _cropApplied,
  );

  /// 原图宽高比，未知时为 0。
  double _imageAspect(int index) {
    final file = _files[index];
    return file.width > 0 && file.height > 0 ? file.width / file.height : 0;
  }

  CropInsets? _cropOf(int index) =>
      _cropApplied ? services.crops.peek(_files[index].hash) : null;

  /// 竖向模式中页面的宽高比：裁掉白边后的比例，未知时按常见的竖版页面估计。
  double _verticalAspect(int index) {
    final aspect = _imageAspect(index);
    if (aspect <= 0) return 0.7;
    final crop = _cropOf(index);
    return crop == null || crop.isZero
        ? aspect
        : crop.croppedAspectRatio(aspect);
  }

  void _retry(int index) =>
      setState(() => _attempts[index] = (_attempts[index] ?? 0) + 1);

  /// 预加载当前屏之后的 N 页和之前的一页。
  void _preload() {
    if (!mounted || _files.isEmpty) return;
    final spreads = _spreads;
    final visible = _vertical || spreads == null
        ? [_page]
        : spreads[spreads.spreadOf(_page)];
    final count = _settings.preloadPages;
    for (final index in [
      for (var i = 1; i <= count; i++) visible.last + i,
      visible.first - 1,
    ]) {
      if (index < 0 || index >= _files.length) continue;
      precacheImage(_provider(index), context, onError: (_, _) {});
    }
  }

  void _setPage(int page) {
    if (page == _page) return;
    setState(() {
      _page = page;
      _zoomed = false;
    });
    services.library.recordRead(widget.gallery, page);
    _preload();
    // 手动翻页后重新计时；竖向模式滚动时会频繁换页，不重置
    if (_autoTurning && !_vertical) _scheduleAutoTurn();
  }

  // ---- 翻页 ----

  bool _wantsDouble(Size size) => switch (_settings.pageLayout) {
    PageLayout.single => false,
    PageLayout.double => true,
    PageLayout.auto => size.width > size.height,
  };

  /// 根据设置和屏幕方向更新分屏；变化时换一个新的 PageController 并停在当前页。
  void _syncSpreads() {
    final key = (
      _wantsDouble(MediaQuery.sizeOf(context)),
      _settings.coverAlone,
    );
    if (_spreads != null && key == _spreadsKey) return;
    _spreadsKey = key;
    final spreads = ReaderSpreads.build(
      _files,
      double: key.$1,
      coverAlone: key.$2,
    );
    _spreads = spreads;
    _animatingTo = null;
    final old = _pageController;
    _pageController = PageController(initialPage: spreads.spreadOf(_page));
    // 旧控制器还挂在即将被替换的 PageView 上，等这一帧结束再释放
    if (old != null) _disposeLater(old);
  }

  void _disposeLater(ChangeNotifier notifier) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => notifier.dispose());

  void _onSpreadChanged(int index) {
    final spreads = _spreads;
    if (spreads == null || index >= spreads.length) return;
    _setPage(spreads[index].first);
  }

  void _goTo(int page, {bool animate = true}) {
    if (_files.isEmpty) return;
    page = page.clamp(0, _files.length - 1);
    if (_vertical) {
      final controller = _scrollController;
      if (controller == null || !controller.hasClients || _offsets.isEmpty) {
        return;
      }
      // 总高度精确，只有最后一屏内的页面会被限制到底部。
      final target = min(_offsets[page], controller.position.maxScrollExtent);
      if (animate) {
        controller.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        controller.jumpTo(target);
      }
      _setPage(page);
    } else {
      final spreads = _spreads;
      if (spreads != null) {
        _goToSpread(spreads.spreadOf(page), animate: animate);
      }
    }
  }

  void _goToSpread(int index, {required bool animate}) {
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return;
    final current = _animatingTo ?? _spreads!.spreadOf(_page);
    if (animate && _settings.pageAnimation && (index - current).abs() == 1) {
      _animatingTo = index;
      controller
          .animateToPage(
            index,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          )
          .whenComplete(() {
            if (_animatingTo == index) _animatingTo = null;
          });
    } else {
      _animatingTo = null;
      controller.jumpToPage(index);
    }
  }

  bool get _atEnd {
    if (_vertical) {
      final controller = _scrollController;
      if (controller == null || !controller.hasClients) return false;
      return controller.position.pixels >=
          controller.position.maxScrollExtent - 1;
    }
    final spreads = _spreads;
    if (spreads == null) return true;
    return (_animatingTo ?? spreads.spreadOf(_page)) >= spreads.length - 1;
  }

  void _next() {
    if (_atEnd) {
      _showEndHint();
    } else if (_vertical) {
      _scrollBy(0.85);
    } else {
      final current = _animatingTo ?? _spreads!.spreadOf(_page);
      _goToSpread(current + 1, animate: true);
    }
  }

  void _previous() {
    if (_vertical) {
      _scrollBy(-0.85);
      return;
    }
    final current = _animatingTo ?? _spreads?.spreadOf(_page) ?? 0;
    if (current > 0) _goToSpread(current - 1, animate: true);
  }

  void _showEndHint() {
    final now = DateTime.now();
    if (now.difference(_lastEndHint) < const Duration(seconds: 2)) return;
    _lastEndHint = now;
    _showMessage('已经是最后一页');
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: action,
          duration: Duration(seconds: action == null ? 2 : 5),
        ),
      );
  }

  /// 桌面端未放大时，滚轮用于翻页。
  void _onWheel(double dy) {
    final now = DateTime.now();
    if (dy == 0 ||
        now.difference(_lastWheel) < const Duration(milliseconds: 180)) {
      return;
    }
    _lastWheel = now;
    dy > 0 ? _next() : _previous();
  }

  /// 竖向模式翻一屏：放大时可见范围变小，按比例减少滚动距离。
  void _scrollBy(double fraction) {
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) return;
    final position = controller.position;
    final scale = _verticalTransform.value.getMaxScaleOnAxis();
    final target =
        (position.pixels + position.viewportDimension * fraction / scale).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    controller.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  // ---- 自动翻页 ----

  void _toggleAutoTurn() {
    if (_autoTurning) {
      _stopAutoTurn();
      return;
    }
    if (_atEnd) {
      _showMessage('已经是最后一页');
      return;
    }
    setState(() => _autoTurning = true);
    _setUi(false);
    _scheduleAutoTurn();
  }

  void _stopAutoTurn() {
    _autoTimer?.cancel();
    if (_autoTurning) setState(() => _autoTurning = false);
  }

  void _scheduleAutoTurn() {
    _autoTimer?.cancel();
    _autoTimer = Timer(
      Duration(seconds: _settings.autoTurnSeconds),
      _autoTurnTick,
    );
  }

  void _autoTurnTick() {
    if (!mounted || !_autoTurning) return;
    if (_atEnd) {
      _stopAutoTurn();
      _showMessage('已到最后一页，自动翻页已停止');
      return;
    }
    // 放大查看时先不翻页
    if (!_zoomed) _next();
    _scheduleAutoTurn();
  }

  // ---- 交互 ----

  void _setMode(ReaderMode mode) {
    if (mode == _mode) return;
    _settings.readerMode = mode;
    final scroll = _scrollController;
    if (scroll != null) {
      scroll.removeListener(_onVerticalScroll);
      _disposeLater(scroll);
    }
    setState(() {
      _mode = mode;
      _zoomed = false;
      _spreads = null;
      _spreadsKey = null;
      _scrollController = null;
      _layoutWidth = 0;
      _verticalTransform.value = Matrix4.identity();
    });
  }

  void _setUi(bool show) {
    if (show == _showUi) return;
    setState(() => _showUi = show);
    _applySystemBars();
  }

  /// 菜单隐藏时沉浸全屏；显示时只露出状态栏。
  ///
  /// 不切换到 edgeToEdge：它会改变窗口适配系统栏的方式，导致整个画面重新布局。
  /// 这两种模式的窗口布局方式相同，状态栏只是盖在预留好的顶栏上方。
  void _applySystemBars() {
    if (_showUi) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const [SystemUiOverlay.top],
      );
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  /// 菜单上下栏预留的系统栏高度，只增不减，系统栏显示与否都不变。
  EdgeInsets _barInsets(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    _statusBarHeight = max(_statusBarHeight, padding.top);
    _navigationBarHeight = max(_navigationBarHeight, padding.bottom);
    return EdgeInsets.only(top: _statusBarHeight, bottom: _navigationBarHeight);
  }

  // ---- 单页菜单（长按 / 右键） ----

  void _showPageMenu(int index) {
    HapticFeedback.mediumImpact();
    final file = _files[index];
    showModalBottomSheet<void>(
      context: _themedContext,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('第 ${index + 1} 页'),
              subtitle: file.width > 0
                  ? Text('${file.width} × ${file.height}')
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('保存图片'),
              subtitle: Text(
                Platform.isAndroid
                    ? '保存到相册（图片/HitomiViewer）'
                    : '保存到“图片\\HitomiViewer”文件夹',
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _savePage(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('重新加载本页'),
              subtitle: const Text('图片显示不正常时使用，会重新下载'),
              onTap: () {
                Navigator.pop(sheetContext);
                _reloadPage(index);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _savePage(int index) async {
    try {
      final bytes = await services.images.load(
        _files[index],
        ImageKind.full,
        localFile: _local(index),
      );
      final number = (index + 1).toString().padLeft(3, '0');
      final saved = await Device.saveImage(
        bytes,
        'hitomi_${widget.gallery.id}_$number',
      );
      if (!mounted) return;
      final file = saved.file;
      _showMessage(
        '已保存到 ${saved.location}',
        action: file != null && Platform.isWindows
            ? SnackBarAction(
                label: '打开文件夹',
                onPressed: () => Device.showInFolder(file),
              )
            : null,
      );
    } catch (error) {
      if (!mounted) return;
      final reason = error is PlatformException
          ? error.message ?? error.code
          : '$error';
      _showMessage('保存失败：$reason');
    }
  }

  /// 删掉缓存的原图和白边检测结果后重新下载（已下载到本地的页面直接重新读取）。
  Future<void> _reloadPage(int index) async {
    final file = _files[index];
    if (_local(index) == null) {
      try {
        await services.images.cacheFile(file, ImageKind.full).delete();
      } on FileSystemException {
        // 没有缓存
      }
    }
    services.crops.forget(file.hash);
    if (mounted) _retry(index);
  }

  void _dismissGuide() {
    setState(() => _showGuide = false);
    if (!_settings.readerGuideShown) _settings.readerGuideShown = true;
  }

  void _handleTap(Offset position) {
    if (_showUi) {
      _setUi(false);
      return;
    }
    if (!_settings.tapToTurn) {
      _setUi(true);
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final third = width / 3;
    final rtl = _mode == ReaderMode.rightToLeft;
    if (position.dx < third) {
      rtl ? _next() : _previous();
    } else if (position.dx > width - third) {
      rtl ? _previous() : _next();
    } else {
      _setUi(true);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final rtl = _mode == ReaderMode.rightToLeft;
    final control = HardwareKeyboard.instance.isControlPressed;
    if (key == LogicalKeyboardKey.audioVolumeDown ||
        key == LogicalKeyboardKey.audioVolumeUp) {
      // 未开启时交还给系统调节音量
      if (!_settings.volumeKeys ||
          defaultTargetPlatform != TargetPlatform.android) {
        return KeyEventResult.ignored;
      }
      final down = key == LogicalKeyboardKey.audioVolumeDown;
      down != _settings.volumeKeysInverted ? _next() : _previous();
    } else if (control &&
        _vertical &&
        (key == LogicalKeyboardKey.equal ||
            key == LogicalKeyboardKey.numpadAdd)) {
      _zoomVertical(1.15);
    } else if (control &&
        _vertical &&
        (key == LogicalKeyboardKey.minus ||
            key == LogicalKeyboardKey.numpadSubtract)) {
      _zoomVertical(1 / 1.15);
    } else if (control && _vertical && key == LogicalKeyboardKey.digit0) {
      _settings.verticalWidth = 960;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      rtl ? _previous() : _next();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      rtl ? _next() : _previous();
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _next();
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      _previous();
    } else if (key == LogicalKeyboardKey.home) {
      _goTo(0, animate: false);
    } else if (key == LogicalKeyboardKey.end) {
      _goTo(_files.length - 1, animate: false);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.keyM) {
      _setUi(!_showUi);
    } else if (key == LogicalKeyboardKey.escape) {
      if (_showGuide) {
        _dismissGuide();
      } else if (_showUi) {
        _setUi(false);
      } else {
        Navigator.maybePop(context);
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _openThumbnails() async {
    final page = await showThumbnailSheet(
      _themedContext,
      files: _files,
      current: _page,
      localFile: _local,
    );
    if (page == null || !mounted) return;
    _setUi(false);
    _goTo(page, animate: false);
  }

  void _openSettings() => showReaderSettings(
    _themedContext,
    mode: () => _mode,
    onModeChanged: _setMode,
    onShowGuide: () {
      _setUi(false);
      setState(() => _showGuide = true);
    },
  );

  void _cycleLayout() {
    const order = [PageLayout.single, PageLayout.double, PageLayout.auto];
    final next = order[(order.indexOf(_settings.pageLayout) + 1) % 3];
    _settings.pageLayout = next;
    _showMessage(switch (next) {
      PageLayout.single => '单页显示',
      PageLayout.double => '双页显示',
      PageLayout.auto => '自动：横屏时双页，竖屏时单页',
    });
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    if (_files.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('没有图片')),
      );
    }
    final dim = _settings.readerDim;
    return Theme(
      data: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Theme.of(context).colorScheme.primary,
        useMaterial3: true,
      ),
      // 状态栏盖在深色顶栏上方，用浅色图标
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
        ),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: Stack(
              key: _themedKey,
              // 每层都有固定的 key：前面的页码层按条件出现或消失时，后面的层不会错位复用
              // （否则底栏会接着顶栏的动画状态，从上方落下来）。
              children: [
                Positioned.fill(
                  key: const ValueKey('reader-content'),
                  child: _vertical ? _verticalView() : _pagedView(),
                ),
                if (dim > 0)
                  Positioned.fill(
                    key: const ValueKey('reader-dim'),
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: dim / 100),
                      ),
                    ),
                  ),
                if (!_showUi && _settings.readerInfo) _infoBar(),
                _topBar(),
                _bottomBar(),
                if (_showGuide)
                  Positioned.fill(
                    key: const ValueKey('reader-guide'),
                    child: ReaderTapGuide(
                      mode: _mode,
                      tapToTurn: _settings.tapToTurn,
                      onDismiss: _dismissGuide,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pageImage(int index, {Alignment alignment = Alignment.center}) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _showPageMenu(index),
        onSecondaryTapUp: (_) => _showPageMenu(index),
        child: ReaderPageImage(
          key: ValueKey('reader-page-$index'),
          provider: _provider(index),
          pageNumber: index + 1,
          onRetry: () => _retry(index),
          alignment: alignment,
          aspectRatio: _imageAspect(index),
          crop: _cropApplied ? () => _cropOf(index) : null,
        ),
      );

  Widget _pagedView() {
    _syncSpreads();
    final spreads = _spreads!;
    final rtl = _mode == ReaderMode.rightToLeft;
    return PageView.builder(
      key: ValueKey((_mode, _spreadsKey)),
      controller: _pageController,
      reverse: rtl,
      physics: _zoomed
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: spreads.length,
      onPageChanged: _onSpreadChanged,
      itemBuilder: (context, index) {
        final pages = spreads[index];
        return ZoomablePage(
          key: ValueKey(pages.first),
          onTap: _handleTap,
          onWheel: _onWheel,
          onZoomChanged: (zoomed) {
            if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
          },
          child: pages.length == 1
              ? _pageImage(pages.first)
              // 两页向中缝靠拢；从右到左时第一页在右边
              : Row(
                  textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _pageImage(
                        pages[0],
                        alignment: rtl
                            ? Alignment.centerLeft
                            : Alignment.centerRight,
                      ),
                    ),
                    Expanded(
                      child: _pageImage(
                        pages[1],
                        alignment: rtl
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _verticalView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = min(
          constraints.maxWidth,
          _settings.verticalWidth.toDouble(),
        );
        if (width != _layoutWidth || _offsetsDirty) _relayoutVertical(width);
        return VerticalZoom(
          controller: _verticalTransform,
          onTap: _handleTap,
          builder: (context, pinching) => ListView.builder(
            controller: _scrollController,
            // 不指定时 ListView 会自动加上系统栏边距，状态栏出现或消失时整页上下跳动
            padding: EdgeInsets.zero,
            // 双指缩放时禁止列表滚动，手势交给缩放
            physics: pinching ? const NeverScrollableScrollPhysics() : null,
            scrollCacheExtent: const ScrollCacheExtent.viewport(1.5),
            itemCount: _files.length,
            // 每页高度已知，提供给列表后总高度精确，跳页不会因估算而偏差。
            itemExtentBuilder: (index, _) => index < _files.length
                ? _offsets[index + 1] - _offsets[index]
                : null,
            itemBuilder: (context, index) {
              final Widget page = Center(
                child: SizedBox(
                  width: width,
                  height: _offsets[index + 1] - _offsets[index],
                  child: _pageImage(index),
                ),
              );
              if (!isDesktop) return page;
              // 比列表更深的监听者先登记滚轮事件，Ctrl + 滚轮就不会滚动列表
              return Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: _onVerticalSignal,
                child: page,
              );
            },
          ),
        );
      },
    );
  }

  /// 宽度或页面比例（裁切白边）变化时重新计算每页位置，并让视口顶部停在同一页的同一位置。
  ///
  /// 在布局阶段直接修正滚动位置（锚点页），上方页面变高变矮时画面不会跳动。
  void _relayoutVertical(double width) {
    final controller = _scrollController;
    final position = controller != null && controller.hasClients
        ? controller.position
        : null;
    int? anchor;
    var fraction = 0.0;
    if (position != null && position.hasPixels && _offsets.length > 1) {
      final offset = position.pixels;
      anchor = _verticalPageAt(offset);
      final height = _offsets[anchor + 1] - _offsets[anchor];
      if (height > 0) {
        fraction = ((offset - _offsets[anchor]) / height).clamp(0.0, 1.0);
      }
    }
    _layoutWidth = width;
    _offsetsDirty = false;
    final offsets = <double>[0];
    for (var i = 0; i < _files.length; i++) {
      offsets.add(offsets.last + width / _verticalAspect(i));
    }
    _offsets = offsets;
    if (controller == null) {
      _scrollController = ScrollController(initialScrollOffset: offsets[_page])
        ..addListener(_onVerticalScroll);
    } else if (position != null && anchor != null) {
      final viewport = position.hasViewportDimension
          ? position.viewportDimension
          : 0.0;
      final target =
          (offsets[anchor] + fraction * (offsets[anchor + 1] - offsets[anchor]))
              .clamp(0.0, max(0.0, offsets.last - viewport));
      if ((target - position.pixels).abs() > 0.5) {
        position.correctBy(target - position.pixels);
      }
    }
  }

  int _verticalPageAt(double offset) {
    var low = 0;
    var high = _files.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_offsets[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  void _onVerticalScroll() {
    final controller = _scrollController;
    if (controller == null || _offsets.length < 2) return;
    // 可见区域上方 1/3 处所在的页面作为当前页；放大时可见区域只是视口的一部分。
    final matrix = _verticalTransform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final top = -matrix.getTranslation().y / scale;
    final probe =
        controller.offset +
        top +
        controller.position.viewportDimension / 3 / scale;
    _setPage(_verticalPageAt(probe));
  }

  void _onVerticalSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      // 滚轮每格（120）约 11%
      (event) => _zoomVertical(
        exp(-(event as PointerScrollEvent).scrollDelta.dy / 1000),
      ),
    );
  }

  /// 桌面端竖向模式调整图片宽度。
  void _zoomVertical(double factor) {
    final current = min(
      _settings.verticalWidth.toDouble(),
      MediaQuery.sizeOf(context).width,
    );
    _settings.verticalWidth = (current * factor).clamp(240.0, 4000.0).round();
  }

  String _pageLabel() {
    final total = _files.length;
    final slider = _sliderPage;
    if (slider != null) return '${slider + 1} / $total';
    final spreads = _spreads;
    final pages = _vertical || spreads == null
        ? [_page]
        : spreads[spreads.spreadOf(_page)];
    final range = pages.length == 2
        ? '${pages[0] + 1}-${pages[1] + 1}'
        : '${pages[0] + 1}';
    return '$range / $total';
  }

  Widget _topBar() {
    // 只有这个 Builder 依赖系统栏高度，系统栏变化时不会重建整个阅读页
    return Positioned(
      key: const ValueKey('reader-top-bar'),
      top: 0,
      left: 0,
      right: 0,
      child: Builder(
        builder: (context) {
          final top = _barInsets(context).top;
          return IgnorePointer(
            ignoring: !_showUi,
            child: AnimatedSlide(
              offset: _showUi ? Offset.zero : const Offset(0, -1),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: Material(
                color: Colors.black.withValues(alpha: 0.8),
                child: Padding(
                  padding: EdgeInsets.only(top: top),
                  child: SizedBox(
                    height: kToolbarHeight,
                    child: Row(
                      children: [
                        const BackButton(color: Colors.white),
                        Expanded(
                          child: Text(
                            widget.gallery.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        PopupMenuButton<ReaderMode>(
                          tooltip: '阅读模式',
                          icon: const Icon(
                            Icons.chrome_reader_mode_outlined,
                            color: Colors.white,
                          ),
                          initialValue: _mode,
                          onSelected: _setMode,
                          itemBuilder: (context) => [
                            for (final mode in ReaderMode.values)
                              CheckedPopupMenuItem(
                                value: mode,
                                checked: mode == _mode,
                                child: Text(mode.label),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bottomBar() {
    return Positioned(
      key: const ValueKey('reader-bottom-bar'),
      left: 0,
      right: 0,
      bottom: 0,
      child: Builder(
        builder: (context) => _bottomBarContent(_barInsets(context).bottom),
      ),
    );
  }

  Widget _bottomBarContent(double bottom) {
    final total = _files.length;
    final rtl = _mode == ReaderMode.rightToLeft;
    // 按钮箭头与进度条方向一致：从右到左时左边的按钮是下一页
    final leftButton = IconButton(
      tooltip: rtl ? '下一页' : '上一页',
      color: Colors.white,
      icon: const Icon(Icons.skip_previous),
      onPressed: rtl ? _nextButton : _previousButton,
    );
    final rightButton = IconButton(
      tooltip: rtl ? '上一页' : '下一页',
      color: Colors.white,
      icon: const Icon(Icons.skip_next),
      onPressed: rtl ? _previousButton : _nextButton,
    );
    final layout = _settings.pageLayout;
    return IgnorePointer(
      ignoring: !_showUi,
      child: AnimatedSlide(
        offset: _showUi ? Offset.zero : const Offset(0, 1),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        child: Material(
          color: Colors.black.withValues(alpha: 0.8),
          child: Padding(
            padding: EdgeInsets.fromLTRB(8, 4, 8, 4 + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    leftButton,
                    Expanded(
                      child: total > 1
                          ? Directionality(
                              textDirection: rtl
                                  ? TextDirection.rtl
                                  : TextDirection.ltr,
                              // 拖动时只更新页码显示，松手才跳页，避免拖动途中请求大量图片。
                              child: Slider(
                                value: (_sliderPage ?? _page).toDouble(),
                                min: 0,
                                max: (total - 1).toDouble(),
                                divisions: total - 1,
                                label: '${(_sliderPage ?? _page) + 1}',
                                onChanged: (value) =>
                                    setState(() => _sliderPage = value.round()),
                                onChangeEnd: (value) {
                                  setState(() => _sliderPage = null);
                                  _goTo(value.round(), animate: false);
                                },
                              ),
                            )
                          : const SizedBox(),
                    ),
                    Text(
                      _pageLabel(),
                      style: const TextStyle(color: Colors.white),
                    ),
                    rightButton,
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _BarAction(
                      icon: Icons.grid_view,
                      label: '缩略图',
                      onPressed: _openThumbnails,
                    ),
                    _BarAction(
                      icon: _autoTurning
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline,
                      label: _autoTurning ? '停止翻页' : '自动翻页',
                      onPressed: _toggleAutoTurn,
                    ),
                    if (!_vertical)
                      _BarAction(
                        icon: switch (layout) {
                          PageLayout.single => Icons.crop_portrait,
                          PageLayout.double => Icons.menu_book_outlined,
                          PageLayout.auto => Icons.screen_rotation_outlined,
                        },
                        label: switch (layout) {
                          PageLayout.single => '单页',
                          PageLayout.double => '双页',
                          PageLayout.auto => '自动单双页',
                        },
                        onPressed: _cycleLayout,
                      ),
                    _BarAction(
                      icon: Icons.tune,
                      label: '阅读设置',
                      onPressed: _openSettings,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  VoidCallback? get _previousButton {
    final spreads = _spreads;
    if (_vertical || spreads == null) {
      return _page > 0 ? () => _goTo(_page - 1, animate: false) : null;
    }
    final current = spreads.spreadOf(_page);
    return current > 0 ? () => _goToSpread(current - 1, animate: false) : null;
  }

  VoidCallback? get _nextButton {
    if (_vertical) {
      return _page < _files.length - 1
          ? () => _goTo(_page + 1, animate: false)
          : null;
    }
    final spreads = _spreads;
    if (spreads == null) return null;
    final current = spreads.spreadOf(_page);
    return current < spreads.length - 1
        ? () => _goToSpread(current + 1, animate: false)
        : null;
  }

  /// 页码、时间和电量，菜单隐藏时显示在右下角。
  Widget _infoBar() {
    const style = TextStyle(color: Colors.white70, fontSize: 12);
    final battery = _battery;
    final time =
        '${_now.hour.toString().padLeft(2, '0')}:'
        '${_now.minute.toString().padLeft(2, '0')}';
    final low = battery != null && battery.level <= 15 && !battery.charging;
    // 全屏时没有系统栏，固定贴近右下角（不随系统栏变化移动）
    return Positioned(
      key: const ValueKey('reader-info-bar'),
      right: 12,
      bottom: 6,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('reader-info'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_autoTurning) ...[
                const Icon(Icons.play_arrow, size: 14, color: Colors.white70),
                const SizedBox(width: 2),
              ],
              Text(_pageLabel(), style: style),
              const SizedBox(width: 8),
              Text(time, style: style),
              if (battery != null) ...[
                const SizedBox(width: 8),
                Icon(
                  battery.charging
                      ? Icons.battery_charging_full
                      : low
                      ? Icons.battery_alert
                      : Icons.battery_std,
                  size: 13,
                  color: low ? Colors.redAccent : Colors.white70,
                ),
                Text(
                  '${battery.level}%',
                  style: low ? style.copyWith(color: Colors.redAccent) : style,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
