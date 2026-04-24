import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_toolkit/flutter_toolkit.dart';

enum ConcurrencyExecutorStrategy {
  /// Отменяет предыдущий запрос и запускает новый.
  /// Используется когда важен только последний результат (например, поиск по вводу)
  switchMap,

  /// Игнорирует новые вызовы пока выполняется текущий того же типа.
  /// Новый вызов получает Future уже выполняющейся операции.
  /// Используется для защиты от дублирующих действий
  /// (двойной тап по кнопке оплаты, повторная отправка формы).
  exhaustMap,

  /// Присоединяется к пулу отменяемых задач.
  /// Используется когда все результаты важны.
  /// При отмене все задачи которые были запущены вернут `ConcurrencyExecutorCancelledResult`
  mergeMap,

  /// Выполняет запросы по очереди, ждёт завершения предыдущего.
  /// Используется когда важен порядок выполнения
  concatMap,
}

typedef ConcurrencyExecutorHandler<T> = Future<T> Function(
  ConcurrencyExecutorItem handler,
);

sealed class ConcurrencyExecutorResult<T> with EquatableMixin {
  const ConcurrencyExecutorResult(this.id);

  final int id;

  const factory ConcurrencyExecutorResult.cancelled(
    int id, [
    OperationResult<T>? result,
  ]) = ConcurrencyExecutorCancelledResult;

  const factory ConcurrencyExecutorResult.success(
    int id,
    OperationResult<T> result,
  ) = ConcurrencyExecutorSuccessResult;

  bool get isCancelled {
    return map(
          onCancelled: (result) => true,
        ) ??
        false;
  }

  bool get isSuccess {
    return map(
          onSuccess: (result) => true,
        ) ??
        false;
  }

  WhenValue when<WhenValue>({
    required WhenValue Function(ConcurrencyExecutorSuccessResult<T> result)
        onSuccess,
    required WhenValue Function(ConcurrencyExecutorCancelledResult<T> result)
        onCancelled,
  }) {
    final result = this;
    return switch (result) {
      ConcurrencyExecutorCancelledResult<T> _ => onCancelled(result),
      ConcurrencyExecutorSuccessResult<T> _ => onSuccess(result),
    };
  }

  MapValue? map<MapValue>({
    MapValue? Function(ConcurrencyExecutorSuccessResult<T> result)? onSuccess,
    MapValue? Function(ConcurrencyExecutorCancelledResult<T> result)?
        onCancelled,
  }) {
    return when(
      onSuccess: (result) => onSuccess?.call(result),
      onCancelled: (result) => onCancelled?.call(result),
    );
  }

  @override
  List<Object?> get props => [id];
}

class ConcurrencyExecutorCancelledResult<T>
    extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorCancelledResult(super.id, [this.result]);

  final OperationResult<T>? result;

  @override
  List<Object?> get props => [...super.props, result];
}

class ConcurrencyExecutorSuccessResult<T> extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorSuccessResult(super.id, this.result);

  final OperationResult<T> result;

  @override
  List<Object?> get props => [...super.props, result];
}

class ConcurrencyExecutorItem<T> {
  ConcurrencyExecutorItem({
    required this.id,
    void Function()? onDone,
    void Function()? onStart,
    required ConcurrencyExecutorHandler<T> handler,
    CancelToken? cancelToken,
  })  : _onDone = onDone,
        _onStart = onStart,
        _handler = handler {
    this.cancelToken = cancelToken ?? CancelToken();
    if (this.cancelToken.isCancelled) {
      cancel();
    }
  }

  final int id;
  final void Function()? _onDone;
  final void Function()? _onStart;
  final FlexibleCompleter<ConcurrencyExecutorResult<T>> _completer =
      FlexibleCompleter();
  late final CancelToken cancelToken;
  final ConcurrencyExecutorHandler<T> _handler;
  bool _started = false;

  bool get isCompleted => _completer.isCompleted;

  bool get isProcessing => _started && !isCompleted;

  bool get inQueue => !isCompleted && !_started;

  bool get isCancelled {
    final value = _completer.value;
    if (value == null) {
      return false;
    }
    return value.isCancelled;
  }

  Future<ConcurrencyExecutorResult<T>> get future => _completer.future;

  Future<void> _start() async {
    if (isCompleted || _started) return;
    _started = true;
    _onStart?.call();
    final result = await _handler(this).safeExecute();
    if (!isCompleted) {
      _completer.complete(
        ConcurrencyExecutorResult.success(id, result),
      );
      _onDone?.call();
    }
  }

  void cancel() {
    if (isCompleted || isCancelled) return;
    if (!cancelToken.isCancelled) {
      cancelToken.cancel();
    }
    _completer.complete(
      ConcurrencyExecutorResult.cancelled(id),
    );
    _onDone?.call();
  }
}

class ConcurrencyExecutor<T> {
  ConcurrencyExecutor({
    this.strategy = ConcurrencyExecutorStrategy.switchMap,
    this.mergeCalls = false,
  });

  final IntGenerator _idGenerator = IntGenerator();

  /// Если этот параметр включен,
  /// несколько вызывов будут получать один результат
  /// если это возможно
  final bool mergeCalls;
  final ConcurrencyExecutorStrategy strategy;
  final SplayTreeMap<int, ConcurrencyExecutorItem<T>> _executorMap =
      SplayTreeMap();
  bool _disposed = false;

  bool get isProcessing {
    return _executorMap.isNotEmpty;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll();
  }

  void cancelAll() {
    return _cancel();
  }

  void cancelById(int id) {
    return _cancel(id: id);
  }

  void _cancel({int? id}) {
    if (id != null) {
      final item = _executorMap.remove(id);
      item?.cancel();
    } else {
      while (_executorMap.isNotEmpty) {
        final item = _executorMap.remove(_executorMap.entries.first.key)!;
        item.cancel();
      }
    }
  }

  ConcurrencyExecutorItem<T>? findExecutorById(int id) {
    return _executorMap[id];
  }

  void _onExecutorDone(int id) {
    _executorMap.remove(id);
    if (_executorMap.isNotEmpty) {
      final next = _executorMap.entries.first.value;
      if (next.inQueue && strategy == ConcurrencyExecutorStrategy.concatMap) {
        next._start();
      }
    }
  }

  Future<ConcurrencyExecutorResult<T>> execute(
    ConcurrencyExecutorHandler<T> handler, {
    void Function(int id)? onStart,
    void Function(ConcurrencyExecutorSuccessResult<T> result)? onSuccess,
    void Function(ConcurrencyExecutorCancelledResult<T> result)? onCancelled,
  }) async {
    var needCancel = _disposed;
    switch (strategy) {
      case ConcurrencyExecutorStrategy.concatMap:
      case ConcurrencyExecutorStrategy.mergeMap:
        break;
      case ConcurrencyExecutorStrategy.exhaustMap:
        final executor = _executorMap.entries.firstOrNull?.value;
        if (executor != null) {
          if (mergeCalls) {
            return executor.future;
          } else {
            needCancel = true;
          }
        }
        break;
      case ConcurrencyExecutorStrategy.switchMap:
        if (mergeCalls) {
          // TODO:
        } else {
          cancelAll();
        }
        break;
    }

    final id = _idGenerator.generate();
    final executorItem = ConcurrencyExecutorItem<T>(
      id: id,
      handler: handler,
      onStart: () => onStart?.call(id),
      onDone: () => _onExecutorDone(id),
    );
    if (needCancel) {
      executorItem.cancel();
    } else {
      if (strategy == ConcurrencyExecutorStrategy.concatMap) {
        if (!isProcessing) {
          executorItem._start();
        }
      } else {
        executorItem._start();
      }
      _executorMap[id] = executorItem;
    }

    return executorItem.future
      ..then(
        (value) {
          value.map(
            onSuccess: onSuccess,
            onCancelled: onCancelled,
          );
        },
      );
  }
}
