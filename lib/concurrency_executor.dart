import 'dart:async';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_toolkit/flutter_toolkit.dart';

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

typedef ConcurrencyExecutorHandler<T> = Future<T> Function(
  CancelToken cancelToken,
);

sealed class ConcurrencyExecutorResult<T> with EquatableMixin {
  const ConcurrencyExecutorResult(this.id);

  final int id;

  const factory ConcurrencyExecutorResult.skip(int id) =
      ConcurrencyExecutorSkipResult;

  const factory ConcurrencyExecutorResult.cancelled(
      int id, OperationResult<T> result) = ConcurrencyExecutorCancelledResult;

  const factory ConcurrencyExecutorResult.success(
      int id, OperationResult<T> result) = ConcurrencyExecutorSuccessResult;

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

  @override
  List<Object?> get props => [id];
}

class ConcurrencyExecutorSkipResult<T> extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorSkipResult(super.id);

  @override
  List<Object?> get props => [...super.props];
}

class ConcurrencyExecutorCancelledResult<T>
    extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorCancelledResult(super.id, this.result);
  final OperationResult<T> result;

  @override
  List<Object?> get props => [result];
}

class ConcurrencyExecutorSuccessResult<T> extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorSuccessResult(super.id, this.result);

  final OperationResult<T> result;

  @override
  List<Object?> get props => [result];
}

class ConcurrencyExecutor<T> {
  ConcurrencyExecutor({
    this.strategy = ConcurrencyExecutorStrategy.switchMap,
  });

  final IntGenerator _idGenerator = IntGenerator();
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
    // _completer?.complete(ConcurrencyExecutorCancelledResult(id, result));
    _completer?.cancel();
    final token = _cancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel();
    }
  }

  Future<ConcurrencyExecutorResult<T>> execute(
    ConcurrencyExecutorHandler<T> handler, {
    ConcurrencyExecutorStrategy? strategy,
    void Function(int id)? onStart,
    void Function(ConcurrencyExecutorSuccessResult<T> result)? onSuccess,
    void Function(ConcurrencyExecutorSkipResult<T> result)? onSkip,
    void Function(ConcurrencyExecutorCancelledResult<T> result)? onCancel,
  }) async {
    final id = _idGenerator.generate();
    final resultStrategy = strategy ?? this.strategy;
    switch (resultStrategy) {
      case ConcurrencyExecutorStrategy.concatMap:
        while (isRunning) {
          await _completer?.future;
        }

        /// TODO: нужно сделать так чтобы `ConcurrencyExecutorResult<T>`
        /// всегда возвращался но в очереди

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

    onStart?.call(id);
    final result = await handler(cancelToken).safeExecute();
    final concurrencyResult = isSync()
        ? ConcurrencyExecutorResult.success(id, result)
        : ConcurrencyExecutorResult.cancelled(id, result);
    completer.complete(concurrencyResult);
    concurrencyResult.map(
      onSuccess: onSuccess,
      onCancelled: onCancel,
    );
    return concurrencyResult;
  }
}
