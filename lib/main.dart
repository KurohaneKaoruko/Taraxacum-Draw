import 'package:flutter/material.dart';

void main() {
  runApp(const TaraxacumDrawApp());
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
      home: const HomePage(),
    );
  }
}

/// 临时首页：后续任务中替换为房间创建/加入界面（task 4.2）。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TaraxacumDraw')),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.draw, size: 64),
            SizedBox(height: 16),
            Text('蒲公英 · 去中心化联机绘画'),
          ],
        ),
      ),
    );
  }
}
