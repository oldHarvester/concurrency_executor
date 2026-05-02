part of 'concurrency_executor.dart';

typedef PollingExecutorContinueHandler<T> = bool Function(
  OperationResult<T> result,
  int attempts,
);

typedef PollingExecutorCompleteHandler<T> = void Function(
  OperationResult<T> result,
);

typedef PollingExecutorCancelHandler = void Function();

/// Repeatedly executes an async operation until a stop condition is met.
///
/// On each iteration [onResult] is called with the latest result and the
/// current attempt count. Return `true` to schedule another attempt after
/// [restartDuration], or `false` to finish and resolve [execute]'s future.
///
/// Calling [execute] again cancels any in-flight attempt and resets the
/// retry counter, so the executor can be safely reused.
class PollingExecutor<T> {
  PollingExecutor({
    this.debug = false,
  });

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

  /// Number of retries performed in the current polling session.
  int get retries => _retries;

  int _retries = 0;

  /// Cancels any in-flight operation and releases internal resources.
  ///
  /// Call this when the executor is no longer needed (e.g. in `dispose` of a
  /// widget or bloc). After [dispose] the executor must not be used again.
  void dispose() {
    _retries = 0;
    _timer.stop();
    _executor.dispose();
  }

  /// Cancels the current polling session without disposing the executor.
  ///
  /// Resets [retries] to `0` and stops the inter-attempt timer. The executor
  /// can be reused afterwards by calling [execute] again.
  void cancel() {
    _retries = 0;
    _timer.stop();
    _executor.cancelAll();
  }

  /// Starts a new polling session by running [handler] repeatedly.
  ///
  /// Each invocation of [handler] receives a [ConcurrencyExecutorItem] that
  /// can be used to check for cancellation. After each successful result
  /// [onResult] decides whether to retry (`true`) or resolve (`false`).
  ///
  /// If this method is called while a previous session is still active, the
  /// previous session is cancelled first (triggering [onCancel] if set).
  ///
  /// Returns the final [OperationResult] when polling stops, or a cancelled
  /// result if the session was interrupted.
  Future<OperationResult<T>> execute(
    Future<T> Function(
      ConcurrencyExecutorItem<T> item,
    ) handler, {
    required PollingExecutorContinueHandler<T> willContinue,
    PollingExecutorCancelHandler? onCancel,
    PollingExecutorCompleteHandler<T>? onComplete,
    Duration restartDuration = const Duration(seconds: 1),
  }) async {
    cancel();
    final completer = FlexibleCompleter<OperationResult<T>>();
    _completer = completer;

    void cancelHandler() {
      completer.cancel(
        OperationResult.failed(
          error: const FlexibleCompleterException(
            FlexibleCompleterExceptionType.cancelled,
          ),
          stackTrace: StackTrace.current,
          elapsedTime: Duration.zero,
        ),
      );
      _logger.log('cancelled');
      onCancel?.call();
    }

    /// «Цикл retry: пока onResult просит continue (true)
    /// и нас не отменили — повторяем handler
    /// с задержкой restartDuration».
    while (!completer.isCompleted) {
      try {
        if (retries > 0) {
          final completed = await _timer.oneTickStart(restartDuration);
          if (!completed) {
            cancelHandler();
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
              final retry = willContinue.call(result.result, _retries);
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
              cancelHandler();
            },
          );
        }
      } catch (e) {
        cancelHandler();
        rethrow;
      }
    }

    return completer.future;
  }
}
