part of 'concurrency_executor.dart';

/// Called after each attempt to decide whether polling should continue.
///
/// Return `true` to schedule another attempt, `false` to stop and resolve the future.
typedef PollingExecutorContinueHandler<T> = bool Function(
  OperationResult<T> result,
  int attempts,
);

/// Called once when the polling session finishes (success or error).
typedef PollingExecutorCompleteHandler<T> = void Function(
  OperationResult<T> result,
);

/// Called when polling ends with a successful result.
typedef PollingExecutorSuccessComplete<T> = void Function(T result);

/// Called when polling ends with an error.
typedef PollingExecutorErrorComplete = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Called when the polling session is cancelled.
typedef PollingExecutorCancelHandler = void Function();

/// The async operation executed on each polling iteration.
///
/// Receives a [ConcurrencyExecutorItem] that can be checked for cancellation.
typedef PollingExecutorHandler<T> = Future<T> Function(
  ConcurrencyExecutorItem<T> item,
);

/// Repeatedly executes an async operation until a stop condition is met.
///
/// On each iteration [willContinue] is called with the latest result and the
/// current attempt count. Return `true` to schedule another attempt after
/// [restartDuration], or `false` to stop and resolve [execute]'s future.
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
  FlexibleCompleter<T>? _completer;

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

  /// Like [execute], but catches errors and cancellations instead of throwing.
  ///
  /// Returns an [OperationResult] so the caller can handle success, error, and
  /// cancel in one place without a `try-catch`.
  Future<OperationResult<T>> safeExecute(
    PollingExecutorHandler<T> handler, {
    required PollingExecutorContinueHandler<T> willContinue,
    PollingExecutorCompleteHandler<T>? onComplete,
    PollingExecutorSuccessComplete<T>? onSuccessComplete,
    PollingExecutorErrorComplete? onErrorComplete,
    PollingExecutorCancelHandler? onCancel,
    Duration restartDuration = const Duration(seconds: 1),
  }) {
    return execute(
      handler,
      willContinue: willContinue,
      onCancel: onCancel,
      onComplete: onComplete,
      onErrorComplete: onErrorComplete,
      onSuccessComplete: onSuccessComplete,
      restartDuration: restartDuration,
    ).safeExecute();
  }

  /// Starts a new polling session by running [handler] repeatedly.
  ///
  /// Each invocation of [handler] receives a [ConcurrencyExecutorItem] that
  /// can be used to check for cancellation. After each result [willContinue]
  /// decides whether to retry (`true`) or stop (`false`).
  ///
  /// If this method is called while a previous session is still active, the
  /// previous session is cancelled first (triggering [onCancel] if set).
  ///
  /// Returns the unwrapped value `T` when polling stops, or throws if the
  /// session completes with an error or is cancelled.
  Future<T> execute(
    PollingExecutorHandler<T> handler, {
    required PollingExecutorContinueHandler<T> willContinue,
    PollingExecutorCompleteHandler<T>? onComplete,
    PollingExecutorSuccessComplete<T>? onSuccessComplete,
    PollingExecutorErrorComplete? onErrorComplete,
    PollingExecutorCancelHandler? onCancel,
    Duration restartDuration = const Duration(seconds: 1),
  }) async {
    cancel();
    final completer = FlexibleCompleter<T>();
    _completer = completer;

    void cancelHandler() {
      completer.cancel();
      _logger.log('cancelled');
      onCancel?.call();
    }

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
                result.result.when(
                  onSuccess: (result) {
                    completer.complete(result);
                    onSuccessComplete?.call(result);
                  },
                  onError: (error, stackTrace) {
                    completer.completeError(error, stackTrace);
                    onErrorComplete?.call(error, stackTrace);
                  },
                );
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
