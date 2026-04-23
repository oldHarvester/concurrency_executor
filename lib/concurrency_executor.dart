import 'dart:async';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_toolkit/core/models/operation_result.dart';
import 'package:flutter_toolkit/extensions/future_or_extension.dart';
import 'package:flutter_toolkit/utils/completers/flexible_completer.dart';

enum ConcurrencyExecutorStrategy {
  /// Отменяет предыдущий запрос и запускает новый.
  /// Используется когда важен только последний результат (например, поиск по вводу)
  switchMap,

  /// Игнорирует новые запросы пока выполняется текущий.
  /// Используется когда нельзя дублировать запрос (например, кнопка оплаты)
  exhaustMap,

  /// Выполняет все запросы параллельно, не отменяя предыдущие.
  /// Используется когда все результаты важны
  mergeMap,

  /// Выполняет запросы по очереди, ждёт завершения предыдущего.
  /// Используется когда важен порядок выполнения
  concatMap,
}

typedef ConcurrencyExecutorHandler<T> = FutureOr<T> Function(
  CancelToken cancelToken,
);

enum ConcurrencySkipReason {
  /// операция уже выполняется (exhaustMap)
  alreadyInProgress,

  /// отменена в процессе выполнения (switchMap)
  cancelledInFlight,
}

sealed class ConcurrencyExecutorResult<T> with EquatableMixin {
  const ConcurrencyExecutorResult();

  const factory ConcurrencyExecutorResult.skip() =
      ConcurrencyExecutorSkipResult;

  const factory ConcurrencyExecutorResult.cancelled(OperationResult<T> result) =
      ConcurrencyExecutorCancelledResult;

  const factory ConcurrencyExecutorResult.success(OperationResult<T> result) =
      ConcurrencyExecutorSuccessResult;

  WhenValue when<WhenValue>({
    required WhenValue Function(ConcurrencyExecutorSkipResult<T> result) onSkip,
    required WhenValue Function(ConcurrencyExecutorSuccessResult<T> result)
        onSuccess,
    required WhenValue Function(ConcurrencyExecutorCancelledResult<T> result)
        onCancelled,
  }) {
    final result = this;
    return switch (result) {
      ConcurrencyExecutorSkipResult<T> _ => onSkip(result),
      ConcurrencyExecutorCancelledResult<T> _ => onCancelled(result),
      ConcurrencyExecutorSuccessResult<T> _ => onSuccess(result),
    };
  }

  MapValue? map<MapValue>({
    MapValue? Function(ConcurrencyExecutorSkipResult<T> result)? onSkip,
    MapValue? Function(ConcurrencyExecutorSuccessResult<T> result)? onSuccess,
    MapValue? Function(ConcurrencyExecutorCancelledResult<T> result)?
        onCancelled,
  }) {
    return when(
      onSkip: (result) => onSkip?.call(result),
      onSuccess: (result) => onSuccess?.call(result),
      onCancelled: (result) => onCancelled?.call(result),
    );
  }
}

class ConcurrencyExecutorSkipResult<T> extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorSkipResult();

  @override
  List<Object?> get props => [];
}

class ConcurrencyExecutorCancelledResult<T>
    extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorCancelledResult(this.result);
  final OperationResult<T> result;

  @override
  List<Object?> get props => [result];
}

class ConcurrencyExecutorSuccessResult<T> extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorSuccessResult(this.result);

  final OperationResult<T> result;

  @override
  List<Object?> get props => [result];
}

class ConcurrencyExecutor<T> {
  ConcurrencyExecutor({
    this.strategy = ConcurrencyExecutorStrategy.switchMap,
  });

  final ConcurrencyExecutorStrategy strategy;
  FlexibleCompleter<ConcurrencyExecutorResult<T>>? _completer;
  CancelToken? _cancelToken;

  bool get isCancelled {
    final completer = _completer;
    final token = _cancelToken;
    return (completer != null && completer.isCancelled) ||
        (token != null && token.isCancelled);
  }

  bool get isRunning {
    return !isIdle && !isCompleted;
  }

  bool get isCompleted {
    final completer = _completer;
    return (completer != null && completer.isCompleted) || isCancelled;
  }

  bool get isIdle => _cancelToken == null && _completer == null;

  void cancel() {
    _completer?.cancel();
    final token = _cancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel();
    }
  }

  FutureOr<ConcurrencyExecutorResult<T>> execute(
    ConcurrencyExecutorHandler<T> handler, {
    ConcurrencyExecutorStrategy? strategy,
    void Function(ConcurrencyExecutorSuccessResult result)? onSuccess,
    void Function(ConcurrencyExecutorSkipResult result)? onSkip,
  }) async {
    final resultStrategy = strategy ?? this.strategy;

    switch (resultStrategy) {
      case ConcurrencyExecutorStrategy.concatMap:
        // TODO:
        break;
      case ConcurrencyExecutorStrategy.exhaustMap:
        final completer = _completer;
        if (completer != null && !isCompleted) {
          return completer.future;
        }
        break;
      case ConcurrencyExecutorStrategy.mergeMap:
        // Nothing need to do
        break;
      case ConcurrencyExecutorStrategy.switchMap:
        cancel();
        break;
    }

    final completer = FlexibleCompleter<ConcurrencyExecutorResult<T>>();
    final cancelToken = CancelToken();
    _completer = completer;
    _cancelToken = cancelToken;

    bool isSync() {
      final allowCompleter =
          resultStrategy == ConcurrencyExecutorStrategy.mergeMap
              ? true
              : completer.canPerformAction(_completer);
      return allowCompleter && !cancelToken.isCancelled;
    }

    final result = await handler(cancelToken).safeExecute();
    final concurrencyResult = isSync()
        ? ConcurrencyExecutorResult.success(result)
        : ConcurrencyExecutorResult.cancelled(result);
    completer.complete(concurrencyResult);
    concurrencyResult.map(
      onSuccess: onSuccess,
    );
    return concurrencyResult;
  }
}
