/// Formats a byte count for display, e.g. `1.5 KB`.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// Formats a duration for display, e.g. `120 ms` or `2.35 s`.
String formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 1000) return '$ms ms';
  return '${(ms / 1000).toStringAsFixed(2)} s';
}
