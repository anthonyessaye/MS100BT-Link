import 'package:flutter/material.dart';

import 'app_model.dart';
import 'ui/home.dart';
import 'ui/widgets.dart';

void main() => runApp(const MS100BTLinkApp());

class MS100BTLinkApp extends StatefulWidget {
  const MS100BTLinkApp({super.key});

  @override
  State<MS100BTLinkApp> createState() => _MS100BTLinkAppState();
}

class _MS100BTLinkAppState extends State<MS100BTLinkApp> {
  final model = AppModel();

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MS-100BT Link',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: AppColors.accent, brightness: Brightness.dark),
          scaffoldBackgroundColor: AppColors.background,
          useMaterial3: true,
        ),
        home: HomeScreen(model: model),
      );
}
