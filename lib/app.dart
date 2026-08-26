import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'home/remote_home_page.dart';
import 'i18n.dart';
import 'remote/remote_connection.dart';
import 'storage/connection_store.dart';
import 'storage/thread_cache.dart';

class CodeoffApp extends StatefulWidget {
  const CodeoffApp({required this.version, super.key});

  final String version;

  @override
  State<CodeoffApp> createState() => _CodeoffAppState();
}

class _CodeoffAppState extends State<CodeoffApp> {
  final connectionStore = ConnectionStore(const FlutterSecureStorage());
  late final remoteConnection = RemoteConnection(widget.version);
  final threadCache = ThreadCache();

  @override
  void dispose() {
    unawaited(remoteConnection.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xff191a1c);
    final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
    final appLocale = deviceLocale.languageCode == 'zh'
        ? const Locale('zh')
        : const Locale('en');
    return MaterialApp(
      title: 'Codeoff',
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
      home: RemoteHomePage(
        version: widget.version,
        connectionStore: connectionStore,
        remoteConnection: remoteConnection,
        threadCache: threadCache,
      ),
    );
  }
}
