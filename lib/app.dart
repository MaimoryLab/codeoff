import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'home/remote_home_page.dart';
import 'i18n.dart';

class CodexRemoteApp extends StatelessWidget {
  const CodexRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xff191a1c);
    final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
    final appLocale = deviceLocale.languageCode == 'zh'
        ? const Locale('zh')
        : const Locale('en');
    return MaterialApp(
      title: 'Codex Remote',
      locale: appLocale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffd78360),
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xff242528),
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff292a2e),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
        useMaterial3: true,
      ),
      home: const RemoteHomePage(),
    );
  }
}
