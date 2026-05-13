// ignore_for_file: public_member_api_docs, sort_constructors_first
part of 'concurrency_executor.dart';

class PollingExecutorTimeSpent with EquatableMixin {
  const PollingExecutorTimeSpent({
    this.total = Duration.zero,
    this.totalEffective = Duration.zero,
    this.lastEffective = Duration.zero,
    this.last = Duration.zero,
  });

  const PollingExecutorTimeSpent.zero()
      : total = Duration.zero,
        totalEffective = Duration.zero,
        lastEffective = Duration.zero,
        last = Duration.zero;

  /// Total spent time with `restartDuration`
  final Duration total;

  /// Total without `restartDuration`
  final Duration totalEffective;

  final Duration lastEffective;

  final Duration last;

  @override
  List<Object?> get props => [total, totalEffective, lastEffective, last];

  PollingExecutorTimeSpent copyWith({
    Duration? total,
    Duration? totalEffective,
    Duration? lastEffective,
    Duration? last,
  }) {
    return PollingExecutorTimeSpent(
      total: total ?? this.total,
      totalEffective: totalEffective ?? this.totalEffective,
      lastEffective: lastEffective ?? this.lastEffective,
      last: last ?? this.last,
    );
  }
}

class PollingExecutorRecords with EquatableMixin {
  const PollingExecutorRecords({
    this.errorAttempts = 0,
    this.successAttempts = 0,
    this.spentTime = const PollingExecutorTimeSpent.zero(),
  });

  const PollingExecutorRecords.zero()
      : successAttempts = 0,
        errorAttempts = 0,
        spentTime = const PollingExecutorTimeSpent.zero();

  PollingExecutorRecords copyWith({
    int? errorAttempts,
    int? successAttempts,
    PollingExecutorTimeSpent? spentTime,
  }) {
    return PollingExecutorRecords(
      errorAttempts: errorAttempts ?? this.errorAttempts,
      successAttempts: successAttempts ?? this.successAttempts,
      spentTime: spentTime ?? this.spentTime,
    );
  }

  final int successAttempts;
  final int errorAttempts;
  final PollingExecutorTimeSpent spentTime;

  int get attempts => successAttempts + errorAttempts;

  @override
  List<Object?> get props => [successAttempts, errorAttempts, spentTime];
}

/// Called after each attempt to decide whether polling should continue.
///
/// Return `true` to schedule another attempt, `false` to stop and resolve the future.
typedef PollingExecutorContinueHandler<T> = bool Function(
  OperationResult<T> result,
  PollingExecutorRecords records,
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

  StreamController<T>? _streamController;

  Stream<T>? get streamProcess {
    final controller = _streamController;
    if (controller != null && !controller.isClosed) {
      return controller.stream;
    }
    return null;
  }

  Future<T>? get process {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      return completer.future;
    }
    return null;
  }

  /// Number of retries performed in the current polling session.
  PollingExecutorRecords get records => _records;

  PollingExecutorRecords _records = PollingExecutorRecords.zero();

  /// Cancels any in-flight operation and releases internal resources.
  ///
  /// Call this when the executor is no longer needed (e.g. in `dispose` of a
  /// widget or bloc). After [dispose] the executor must not be used again.
  void dispose() {
    _records = PollingExecutorRecords.zero();
    _timer.stop();
    _executor.dispose();
    _streamController?.close();
  }

  /// Cancels the current polling session without disposing the executor.
  ///
  /// Resets [retries] to `0` and stops the inter-attempt timer. The executor
  /// can be reused afterwards by calling [execute] again.
  void cancel() {
    _records = PollingExecutorRecords.zero();
    _timer.stop();
    _executor.cancelAll();
    _streamController?.close();
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

  void _updateRecords(
    Stopwatch watcher,
    Duration restartDuration,
    OperationResult<T> result,
    bool wasWaiting,
  ) {
    final spentTime = _records.spentTime;
    final lastEffective = watcher.elapsed;
    final last = lastEffective + (wasWaiting ? restartDuration : Duration.zero);
    _records = _records.copyWith(
      errorAttempts: result.isSuccess ? null : _records.errorAttempts + 1,
      successAttempts: result.isFailed ? null : _records.successAttempts + 1,
      spentTime: spentTime.copyWith(
        lastEffective: lastEffective,
        last: last,
        total: spentTime.total + last,
        totalEffective: spentTime.totalEffective + lastEffective,
      ),
    );
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
        final wait = records.attempts > 0 && restartDuration > Duration.zero;
        if (wait) {
          final completed = await _timer.oneTickStart(restartDuration);
          if (!completed) {
            cancelHandler();
            continue;
          }
        }
        if (!completer.isCompleted) {
          final Stopwatch watcher = Stopwatch();
          final result = await _executor.execute(
            (item) async {
              return handler(item);
            },
          );
          watcher.stop();
          result.when(
            onComplete: (result) {
              final operationResult = result.result;
              _updateRecords(
                watcher,
                restartDuration,
                operationResult,
                wait,
              );
              final retry = willContinue.call(result.result, records);
              if (retry) {
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

  Stream<T> streamExecute(
    PollingExecutorHandler<T> handler, {
    required PollingExecutorContinueHandler<T> willContinue,
    PollingExecutorCompleteHandler<T>? onComplete,
    PollingExecutorSuccessComplete<T>? onSuccessComplete,
    PollingExecutorErrorComplete? onErrorComplete,
    PollingExecutorCancelHandler? onCancel,
    Duration restartDuration = const Duration(seconds: 1),
  }) {
    final streamController = StreamController<T>.broadcast();
    execute(
      handler,
      willContinue: (result, attempts) {
        result.when(
          onError: (error, stackTrace) {
            streamController.addError(error, stackTrace);
          },
          onSuccess: (result) {
            streamController.add(result);
          },
        );
        return willContinue(result, attempts);
      },
      onCancel: () {
        streamController.addError(
          FlexibleCompleterException(
            FlexibleCompleterExceptionType.cancelled,
          ),
        );
        onCancel?.call();
      },
      onComplete: onComplete,
      onErrorComplete: onErrorComplete,
      onSuccessComplete: onSuccessComplete,
      restartDuration: restartDuration,
    ).then(
      (value) {
        streamController.close();
      },
    );
    _streamController = streamController;

    return streamController.stream;
  }
}
