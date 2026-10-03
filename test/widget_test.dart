import 'package:flutter_test/flutter_test.dart';

import 'package:taraxacum_draw/main.dart';

void main() {
  testWidgets('应用启动并显示首页', (tester) async {
    await tester.pumpWidget(const TaraxacumDrawApp());
    expect(find.text('蒲公英 · 去中心化联机绘画'), findsOneWidget);
  });
}
