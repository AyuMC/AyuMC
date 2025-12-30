/// High-performance network optimization library for AyuMC Server.
///
/// This library provides comprehensive optimization strategies including:
/// - Multi-threaded packet processing via isolate pooling
/// - Memory pooling for zero-allocation buffer management
/// - Connection pooling with load balancing
/// - Network packet batching for reduced syscalls
/// - Adaptive performance tuning
/// - Real-time statistics and monitoring
///
/// Example usage:
/// ```dart
/// import 'package:ayumc_server/core/network/optimization.dart';
///
/// final isolatePool = IsolateWorkerPool();
/// await isolatePool.initialize(workerCount: 4);
///
/// final memoryPool = BufferMemoryPool();
/// memoryPool.initialize();
///
/// final stats = NetworkPerformanceStatistics();
/// stats.recordPacketReceived(256);
/// ```
library;

export 'optimization/adaptive_scheduler.dart';
export 'optimization/connection_pool.dart';
export 'optimization/isolate_pool.dart';
export 'optimization/memory_pool.dart';
export 'optimization/network_statistics.dart';
export 'optimization/packet_batcher.dart';
