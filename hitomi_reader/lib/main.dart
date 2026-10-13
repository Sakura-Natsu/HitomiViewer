import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'pages/home_page.dart';
import 'services/app_services.dart';
import 'services/tag_labels.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppServices.init();
  runApp(const HitomiApp());
}

class HitomiApp extends StatelessWidget {
  const HitomiApp({super.key});

  static const Color _seed = Color(0xFFE0457B);

  ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: brightness),
    visualDensity: VisualDensity.standard,
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) => TagLabelScope(
        labels: services.tagLabels,
        child: MaterialApp(
          title: 'HitomiViewer',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: services.settings.themeMode,
          // 桌面端允许用鼠标拖动翻页、拖动横向列表。
          scrollBehavior: const MaterialScrollBehavior().copyWith(
            dragDevices: PointerDeviceKind.values.toSet(),
          ),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const HomePage(),
        ),
      ),
    );
  }
}
