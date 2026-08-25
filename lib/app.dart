import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'home/remote_home_page.dart';
import 'i18n.dart';

class CodexRemoteApp extends StatefulWidget {
  const CodexRemoteApp({super.key});

  @override
  State<CodexRemoteApp> createState() => _CodexRemoteAppState();
}

class _CodexRemoteAppState extends State<CodexRemoteApp> {
  Locale locale = const Locale('en');

  @override
  Widget build(BuildContext context) {
    const background = Color(0xff191a1c);
    return LocaleScope(
      locale: locale,
      setLocale: (value) => setState(() => locale = value),
      child: MaterialApp(
        title: 'Codex Remote',
        locale: locale,
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
      ),
    );
  }
}
