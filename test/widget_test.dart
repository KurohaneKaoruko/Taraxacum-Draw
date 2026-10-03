import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taraxacum_draw/main.dart';

void main() {
  testWidgets('应用启动并进入画布页', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: TaraxacumDrawApp()));
    expect(find.byKey(const Key('canvas_page')), findsOneWidget);
  });
}
