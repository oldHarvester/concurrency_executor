part of 'concurrency_executor.dart';

class PollingExecutor<T> {
  PollingExecutor({
    this.restartDuration = Duration.zero,
    required this.onResult,
    this.onComplete,
    this.onCancel,
    this.debug = false,
  });

  /// Should return true if need to continue throttling
  final bool Function(OperationResult<T> result, int attempts) onResult;

  final void Function(OperationResult<T> result)? onComplete;

  final void Function()? onCancel;

  /// Duration before restarting request
  final Duration restartDuration;

  final ConcurrencyExecutor<T> _executor = ConcurrencyExecutor(
    strategy: ConcurrencyExecutorStrategy.exhaustMap,
  );

  final bool debug;

  final FlexibleTimer _timer = FlexibleTimer(debug: false);

  late final CustomLogger _logger = CustomLogger(
    owner: 'PollingExecutor',
    showLogs: debug,
  );

  // ignore: unused_field
  FlexibleCompleter<OperationResult<T>>? _completer;

  int get retries => _retries;

  int _retries = 0;

  void dispose() {
    _retries = 0;
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
  ) async {
    cancel();
    final completer = FlexibleCompleter<OperationResult<T>>();
    _completer = completer;

    void onCancel() {
      completer.cancel(
        OperationResult.failed(
          error: const FlexibleCompleterException(
              FlexibleCompleterExceptionType.cancelled),
          stackTrace: StackTrace.current,
          elapsedTime: Duration.zero,
        ),
      );
      _logger.log('cancelled');
      this.onCancel?.call();
    }

    /// «Цикл retry: пока onResult просит continue (true)
    /// и нас не отменили — повторяем handler
    /// с задержкой restartDuration».
    while (!completer.isCompleted) {
      try {
        if (retries > 0) {
          final completed = await _timer.oneTickStart(restartDuration);
          if (!completed) {
            onCancel();
            continue;
          }
        }
        if (!completer.isCompleted) {
          final result = await _executor.execute(
            (item) async {
              return handler(item);
            },
          );
          result.when(
            onComplete: (result) {
              final retry = onResult.call(result.result, _retries);
              if (retry) {
                _retries++;
                _logger.log('on retry result: ${result.result}');
              } else {
                completer.complete(result.result);
                _logger.log('on complete: ${result.result}');
                onComplete?.call(result.result);
              }
            },
            onCancelled: (result) {
              onCancel();
            },
          );
        }
      } catch (e) {
        onCancel();
        rethrow;
      }
    }

    return completer.future;
  }
}
