import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 随滚动收起的顶栏（参照 EhViewer）。
///
/// - 往下滑时，顶栏跟着内容一起滑出屏幕，不占浏览空间；
/// - 在任意位置往上滑一点，顶栏就跟着手指滑回来，不必回到列表顶部；
/// - 滚动停下时，按最后的滑动方向收到完全显示（往上滑）或完全隐藏（往下滑），
///   所以往上轻轻一滑顶栏就会完整出现。
///
/// [body] 里的列表需要在顶部留出 [FloatingHeader.topPaddingOf] 的空间，
/// 这样顶栏完全显示时不会盖住第一项。状态栏那一条始终保留背景色，内容不会透到状态栏下面。
class FloatingHeader extends StatefulWidget {
  const FloatingHeader({super.key, required this.header, required this.body});

  /// 顶栏（不含状态栏），通常是 `AppBar(primary: false, ...)`。
  final PreferredSizeWidget header;
  final Widget body;

  /// 列表顶部需要留出的空间（状态栏 + 顶栏）；不在 [FloatingHeader] 里时为 0。
  static double topPaddingOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_FloatingHeaderScope>()
          ?.topPadding ??
      0;

  @override
  State<FloatingHeader> createState() => FloatingHeaderState();
}

class FloatingHeaderState extends State<FloatingHeader>
    with SingleTickerProviderStateMixin {
  /// 顶栏收起了多少（0 为完全显示，顶栏高度为完全隐藏）。
  double _offset = 0;

  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(_onSnap);
  double _snapFrom = 0;
  double _snapTo = 0;

  /// 最近一次滚动的方向：负数为往上滑（内容向下移动）。
  double _lastDelta = 0;

  double get _height => widget.header.preferredSize.height;

  /// 当前收起的距离，测试用。
  @visibleForTesting
  double get hiddenExtent => _offset;

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  /// 立即完全显示顶栏（例如搜索条件变了、列表回到加载状态时）。
  void show() {
    _snap.stop();
    if (_offset != 0) setState(() => _offset = 0);
  }

  void _onSnap() {
    final value = Curves.easeOut.transform(_snap.value);
    setState(() => _offset = _snapFrom + (_snapTo - _snapFrom) * value);
  }

  void _animateTo(double target) {
    if (target == _offset) return;
    _snapFrom = _offset;
    _snapTo = target;
    _snap.forward(from: 0);
  }

  bool _onScroll(ScrollNotification notification) {
    // 只跟随内容区的竖向列表，不管顶栏里横向滚动的条件列表
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final pixels = notification.metrics.pixels;
    if (notification is ScrollStartNotification) {
      _snap.stop();
    } else if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta != 0) _lastDelta = delta;
      // 跟着滚动距离移动；靠近列表顶部时不能盖住第一项
      final next = min((_offset + delta).clamp(0.0, _height), max(0.0, pixels));
      if (next != _offset) setState(() => _offset = next);
    } else if (notification is ScrollEndNotification) {
      // 停在中间时按最后的方向收起或展开；离顶部不足一个顶栏高度时总是完全显示
      if (_offset > 0 && _offset < _height) {
        _animateTo(_lastDelta > 0 && pixels >= _height ? _height : 0);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusBar = MediaQuery.paddingOf(context).top;
    final background = theme.colorScheme.surface;
    final dark = theme.brightness == Brightness.dark;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        children: [
          Positioned.fill(
            child: _FloatingHeaderScope(
              topPadding: statusBar + _height,
              child: widget.body,
            ),
          ),
          Positioned(
            top: statusBar,
            left: 0,
            right: 0,
            height: _height,
            child: Transform.translate(
              offset: Offset(0, -_offset),
              // 完全收起后不再响应点按
              child: IgnorePointer(
                ignoring: _offset >= _height,
                child: Material(color: background, child: widget.header),
              ),
            ),
          ),
          // 状态栏背景：顶栏从它下面滑过；状态栏图标颜色跟随主题
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: statusBar,
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
                statusBarBrightness: theme.brightness,
              ),
              child: ColoredBox(color: background),
            ),
          ),
        ],
      ),
    );
  }
}

class _FloatingHeaderScope extends InheritedWidget {
  const _FloatingHeaderScope({required this.topPadding, required super.child});

  final double topPadding;

  @override
  bool updateShouldNotify(_FloatingHeaderScope oldWidget) =>
      topPadding != oldWidget.topPadding;
}
