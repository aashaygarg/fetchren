import 'package:flutter/material.dart';

import 'workbench/workbench_controller.dart';
import 'workbench/workbench_screen.dart';

/// Root widget for FetchRen.
class FetchRenApp extends StatelessWidget {
  const FetchRenApp({super.key, required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FetchRen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: WorkbenchScreen(controller: controller),
    );
  }
}
