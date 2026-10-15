/// Seeded 2D gradient noise. The permutation table is built from [seed] with a
/// fixed LCG so the same seed produces the same samples in every isolate.
final class GradientNoise {
  GradientNoise(int seed) : _perm = _permute(seed);

  final List<int> _perm;

  static List<int> _permute(int seed) {
    final perm = List<int>.generate(256, (i) => i);
    var state = (seed ^ 0x9E3779B9) & 0xFFFFFFFF;
    for (var i = 255; i > 0; i--) {
      state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
      final j = (state >> 16) % (i + 1);
      final tmp = perm[i];
      perm[i] = perm[j];
      perm[j] = tmp;
    }
    return perm;
  }

  /// Smooth value in roughly `-1..1` at absolute world coordinates.
  double sample(double x, double z) {
    final x0 = x.floor();
    final z0 = z.floor();
    final xf = x - x0;
    final zf = z - z0;
    final u = _fade(xf);
    final v = _fade(zf);
    final xi = x0 & 255;
    final zi = z0 & 255;
    final aa = _perm[(_perm[xi] + zi) & 255];
    final ab = _perm[(_perm[xi] + ((zi + 1) & 255)) & 255];
    final ba = _perm[(_perm[(xi + 1) & 255] + zi) & 255];
    final bb = _perm[(_perm[(xi + 1) & 255] + ((zi + 1) & 255)) & 255];
    final x1 = _lerp(_grad(aa, xf, zf), _grad(ba, xf - 1, zf), u);
    final x2 = _lerp(_grad(ab, xf, zf - 1), _grad(bb, xf - 1, zf - 1), u);
    return _lerp(x1, x2, v);
  }

  static double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);

  static double _lerp(double a, double b, double t) => a + t * (b - a);

  static double _grad(int hash, double x, double z) {
    return switch (hash & 3) {
      0 => x + z,
      1 => -x + z,
      2 => x - z,
      _ => -x - z,
    };
  }
}
