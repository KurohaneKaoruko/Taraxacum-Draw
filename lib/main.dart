import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:taraxacum_draw/presentation/canvas/canvas_view.dart';

void main() {
  runApp(const ProviderScope(child: TaraxacumDrawApp()));
}

/// TaraxacumDraw（蒲公英）— 去中心化联机绘画应用入口。
class TaraxacumDrawApp extends StatelessWidget {
  const TaraxacumDrawApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TaraxacumDraw',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
      ),
      home: const CanvasPage(),
    );
  }
}
