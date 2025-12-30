import 'dart:collection';
import 'dart:typed_data';
import '../../logging/server_logger.dart';

/// A high-performance memory pool for buffer reuse and allocation optimization.
///
/// The [BufferMemoryPool] manages pre-allocated buffer pools to eliminate
/// garbage collection pressure and reduce memory allocations. It supports
/// multiple pool sizes and automatic size matching.
///
/// Example:
/// ```dart
/// final pool = BufferMemoryPool();
/// pool.initialize();
///
/// final buffer = pool.acquire(1024);
/// Use buffer...
/// pool.release(buffer);
/// ```
class BufferMemoryPool {
  static final BufferMemoryPool _instance = BufferMemoryPool._internal();
  static final ServerLogger _logger = ServerLogger();

  /// Returns the singleton instance of the memory pool.
  factory BufferMemoryPool() => _instance;

  BufferMemoryPool._internal();

  final Map<int, Queue<Uint8List>> _pools = {};
  final Map<int, int> _poolSizes = {};

  static const int kSmallBufferSize = 1024;
  static const int kMediumBufferSize = 4096;
  static const int kLargeBufferSize = 16384;
  static const int kMaxPoolSize = 100;

  /// Initializes the memory pool with pre-allocated buffers.
  void initialize() {
    _createPool(kSmallBufferSize, 50);
    _createPool(kMediumBufferSize, 30);
    _createPool(kLargeBufferSize, 20);

    _logger.info('BufferMemoryPool', 'Initialized with optimized buffer pools');
  }

  void _createPool(int size, int initialCount) {
    final pool = Queue<Uint8List>();

    for (int i = 0; i < initialCount; i++) {
      pool.add(Uint8List(size));
    }

    _pools[size] = pool;
    _poolSizes[size] = initialCount;
  }

  /// Acquires a buffer of at least [requestedSize] bytes from the pool.
  ///
  /// If a pooled buffer is available, it is returned. Otherwise, a new
  /// buffer is allocated. The returned buffer may be larger than requested.
  Uint8List acquire(int requestedSize) {
    final poolSize = _selectNearestPoolSize(requestedSize);

    if (poolSize == null) {
      return Uint8List(requestedSize);
    }

    final pool = _pools[poolSize]!;

    if (pool.isEmpty) {
      return Uint8List(poolSize);
    }

    return pool.removeFirst();
  }

  /// Releases a buffer back to the pool for reuse.
  ///
  /// The buffer is zeroed before being returned to the pool for security.
  /// If the pool is full, the buffer is discarded.
  void release(Uint8List buffer) {
    final size = buffer.length;
    final pool = _pools[size];

    if (pool == null || pool.length >= kMaxPoolSize) {
      return;
    }

    buffer.fillRange(0, buffer.length, 0);
    pool.add(buffer);
  }

  int? _selectNearestPoolSize(int requestedSize) {
    if (requestedSize <= kSmallBufferSize) {
      return kSmallBufferSize;
    }
    if (requestedSize <= kMediumBufferSize) {
      return kMediumBufferSize;
    }
    if (requestedSize <= kLargeBufferSize) {
      return kLargeBufferSize;
    }
    return null;
  }

  /// Returns statistics about the current state of all buffer pools.
  Map<int, int> getStatistics() {
    return _pools.map((size, pool) => MapEntry(size, pool.length));
  }

  /// Clears all pools, releasing all buffers.
  void clear() {
    for (final pool in _pools.values) {
      pool.clear();
    }
  }
}
