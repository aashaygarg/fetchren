import 'package:flutter/material.dart';

/// Root widget for FetchRen.
class FetchRenApp extends StatelessWidget {
  const FetchRenApp({super.key});

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
      home: const HomeScreen(),
    );
  }
}

/// Placeholder home screen until API-client features are implemented.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('FetchRen', style: textTheme.displaySmall),
            const SizedBox(height: 8),
            Text(
              'Open-source, cross-platform API client',
              style: textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
