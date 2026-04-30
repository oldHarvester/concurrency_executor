part of 'concurrency_executor.dart';

class PollingExecutor<T> {
  PollingExecutor({
    this.restartDuration = Duration.zero,
    required this.onResult,
    this.onComplete,
  });

  /// Should return true if need to continue throttling
  final bool Function(OperationResult<T> result) onResult;

  final void Function(OperationResult<T> result)? onComplete;

  /// Duration before restarting request
  final Duration restartDuration;

  final ConcurrencyExecutor<T> _executor = ConcurrencyExecutor(
    strategy: ConcurrencyExecutorStrategy.exhaustMap,
  );

  final FlexibleTimer _timer = FlexibleTimer();

  FlexibleCompleter<OperationResult<T>>? _completer;

  Future<OperationResult<T>>? get future => _completer?.future;

  int get retries => _retries;

  int _retries = 0;

  void dispose() {
    _timer.stop();
    _executor.dispose();
  }

  void cancel() {
    _retries = 0;
    _timer.stop();
    _executor.cancelAll();
  }

  Future<OperationResult<T>> execute(
    Future<T> Function(
      ConcurrencyExecutorItem<T> item,
    ) handler,
  ) {
    cancel();
    final completer = FlexibleCompleter<OperationResult<T>>();
    _completer = completer;

    Future<void> foo() async {
      final result = await _executor.execute(
        (item) async {
          try {
            if (retries > 0) {
              await _timer.oneTickStart(restartDuration);
              if (item.isCompleted) throw UnimplementedError();
            }
            final result = await handler(item);
            return result;
          } catch (e) {
            rethrow;
          }
        },
      );
      result.when(
        onComplete: (result) {
          final retry = onResult.call(result.result);
          if (retry) {
            _retries++;
            foo();
          } else {
            completer.complete(result.result);
          }
        },
        onCancelled: (result) {
          completer.cancel();
        },
      );
    }

    foo();

    return completer.future;
  }
}
