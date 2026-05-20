String getTime() {
  final now = DateTime.now();

  final hour = now.hour.toString().padLeft(2, '0');
  final minute = now.minute.toString().padLeft(2, '0');
  final second = now.second.toString().padLeft(2, '0');

  return '$hour:$minute:$second';
}
