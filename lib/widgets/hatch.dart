import 'dart:ui';

/// Paints the 45° hatch that marks a stretch of time nobody has data for.
///
/// Shared rather than copied. The stop timeline hatches unscheduled hours and
/// a report's production band hatches no-data segments; both mean "the plant
/// was not being watched here, and none of the durations below counted it".
/// Two copies of this routine would eventually disagree about the angle or the
/// spacing, and then the same idea would read as two different textures.
///
/// The stripes run bottom-left to top-right (45° in screen space only when the
/// rect is square, which is deliberate: the line is drawn across the full
/// height so the texture stays continuous as a band changes height).
void paintHatch(
  Canvas canvas,
  Rect rect,
  Color color, {
  double spacing = 6,
  double strokeWidth = 1,
}) {
  if (rect.isEmpty) return;
  canvas.save();
  canvas.clipRect(rect);
  final paint = Paint()
    ..color = color
    ..strokeWidth = strokeWidth;
  for (var x = rect.left - rect.height; x < rect.right; x += spacing) {
    canvas.drawLine(
        Offset(x, rect.bottom), Offset(x + rect.height, rect.top), paint);
  }
  canvas.restore();
}
