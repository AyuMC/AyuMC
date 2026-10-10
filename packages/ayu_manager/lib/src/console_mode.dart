import 'dart:ffi';
import 'dart:io';

/// Turns on Windows virtual-terminal processing so the manager can redraw in
/// place and receive function keys. Other platforms already speak ANSI.
bool enableTerminalFeatures() {
  if (!Platform.isWindows) return stdout.supportsAnsiEscapes;
  try {
    return _enableWindows();
  } on Object {
    return false;
  }
}

bool _enableWindows() {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final getHandle = kernel
      .lookupFunction<IntPtr Function(Int32), int Function(int)>(
        'GetStdHandle',
      );
  final getMode = kernel
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetConsoleMode');
  final setMode = kernel
      .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
        'SetConsoleMode',
      );
  final alloc = kernel
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Uint32, Uint32),
        int Function(int, int, int, int)
      >('VirtualAlloc');
  final free = kernel
      .lookupFunction<
        Int32 Function(IntPtr, IntPtr, Uint32),
        int Function(int, int, int)
      >('VirtualFree');

  final address = alloc(0, 4, 0x1000 | 0x2000, 0x04);
  if (address == 0) return false;
  final mode = Pointer<Uint32>.fromAddress(address);
  try {
    final output = getHandle(-11);
    final input = getHandle(-10);
    if (getMode(output, mode) == 0) return false;
    if (setMode(output, mode.value | 0x0001 | 0x0004) == 0) return false;
    if (getMode(input, mode) == 0) return false;
    final next = (mode.value | 0x0080 | 0x0200) & ~0x0002 & ~0x0004;
    return setMode(input, next) != 0;
  } finally {
    free(address, 0, 0x8000);
  }
}
