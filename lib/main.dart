import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'routing/app_router.dart';
import 'shared/theme/app_theme.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
// import 'package:flutter_skill/flutter_skill.dart';
// import 'package:flutter_gemma/flutter_gemma.dart';

void main() async {
  // FlutterSkillBinding.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await Firebase.initializeApp();
  // await FlutterGemma.initialize();

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('he'), Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('he'),
      startLocale: const Locale('he'),
      child: const ProviderScope(child: MyApp()),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Pirsumoto',
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark, // Defaulting to dark for modern rich aesthetic
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
