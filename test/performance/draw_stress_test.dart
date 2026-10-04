import 'package:flutter_test/flutter_test.dart';
import 'package:taraxacum_draw/domain/canvas_document.dart';
import 'package:taraxacum_draw/domain/op.dart';
import 'package:taraxacum_draw/domain/stroke.dart';
import 'package:taraxacum_draw/infrastructure/render/layer_raster_cache.dart';

/// 算法层性能压测（task 2.7 自动化近似基线）。
///
/// 注意：这里测量的是 op 入账 / 笔迹录制 / 重放重建的 CPU 耗时，
/// 不是真实 GPU 帧时序；真实 60fps 基线在 task 7.2 于真机
/// （performance overlay）补测，数字记录在 docs/perf-baseline.md。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const strokeCount = 500;
  const pointsPerStroke = 200;

  List<StrokePoint> wavePoints(int seed) => List.generate(pointsPerStroke, (i) {
        final t = i / pointsPerStroke;
        return StrokePoint(
          x: t * 800 + seed % 40,
          y: 300 + (t * 10 % 1 * 50) + ((seed + i) % 7) * 3,
        );
      });

  test('500 笔压测：入账 / 重录 / 重放 / 撤销', () async {
    final doc = CanvasDocument();
    final clock = Stopwatch()..start();

    // 1) 顺序入账 500 笔（快路径，每笔 ~200 点）。
    for (var i = 0; i < strokeCount; i++) {
      doc.applyOp(AddStrokeOp(
        opId: 'o$i',
        authorId: 'local',
        lamport: i + 1,
        wallTimeMs: 0,
        stroke: Stroke(
          id: 's$i',
          authorId: 'local',
          layerId: 'base',
          tool: i % 10 == 0 ? DrawTool.eraser : DrawTool.brush,
          color: 0xFF1A1A1A,
          width: 4,
          points: wavePoints(i),
          createdAtMs: 0,
        ),
      ));
    }
    final applyMs = clock.elapsedMilliseconds;
    expect(doc.strokesOf('base').length, strokeCount);

    // 2) 图层缓存重录（模拟最后一笔完成后的缓存失效重建）。
    clock.reset();
    final picture = LayerRasterCache.recordStrokes(doc.strokesOf('base'));
    final recordMs = clock.elapsedMilliseconds;
    picture.dispose();

    // 3) 一条乱序 op 触发全量重放（同步场景）。
    clock.reset();
    doc.applyOp(ClearCanvasOp(
      opId: 'clear-x',
      authorId: 'peer-b',
      lamport: 0, // 故意乱序，触发 _rebuild
      wallTimeMs: 0,
    ));
    final rebuildMs = clock.elapsedMilliseconds;
    expect(doc.log.length, strokeCount + 2);

    // 4) 撤销重建。
    clock.reset();
    doc.applyOp(UndoOp(
      opId: 'u1',
      authorId: 'local',
      lamport: strokeCount + 10,
      wallTimeMs: 0,
      undoneOpId: 'clear-x',
    ));
    final undoMs = clock.elapsedMilliseconds;
    expect(doc.strokesOf('base').length, strokeCount, reason: '撤销清空恢复全部笔迹');

    // 宽松的回归阈值（正常机器应在个位数秒内完成）。
    expect(applyMs + recordMs + rebuildMs + undoMs, lessThan(60000),
        reason: '压测总耗时应远低于此上限');

    // ignore: avoid_print
    print('PERF-BASELINE apply500=${applyMs}ms record=${recordMs}ms '
        'rebuild=${rebuildMs}ms undo=${undoMs}ms');
  });
}
