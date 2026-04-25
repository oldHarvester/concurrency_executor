import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_toolkit/flutter_toolkit.dart';

extension CancelTokenX on CancelToken {
  bool tryCancel([Object? reason]) {
    try {
      if (!isCancelled) {
        cancel(reason);
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }
}

enum ConcurrencyExecutorStrategy {
  /// Отменяет предыдущие вызовы и запускает новый.
  /// Актуален только последний результат — типичные кейсы:
  /// поиск по вводу, фильтры, автокомплит.
  ///
  /// С shareWithOvertaken=true предыдущие вызывающие не получают cancelled,
  /// а дожидаются результата последнего handler'а — удобно, когда
  /// UI слушает только свой вызов, но должен отобразить актуальные
  /// данные. HTTP-запросы предыдущих при этом всё равно отменяются
  /// через CancelToken.
  ///
  /// С shareWithOvertaken=false предыдущие получают cancelled сразу.
  switchMap,

  /// Дедуплицирует одновременные вызовы: пока операция выполняется,
  /// повторные вызовы не запускают новый handler.
  /// Типичные кейсы: кнопка оплаты, отправка формы, защита от
  /// rapid-клика пользователя.
  ///
  /// С shareWithOvertaken=true повторный вызов получает Future текущей
  /// операции — оба вызывающих получат один и тот же результат
  /// (включая callbacks onSuccess/onCancelled).
  ///
  /// С shareWithOvertaken=false повторный вызов сразу получает cancelled,
  /// текущая операция продолжает выполняться без изменений.
  ///
  /// Важно: executor дженерик по T, поэтому дедупликация идёт
  /// по самому факту активной операции, а не по аргументам handler.
  /// Вызовы execute(() => pay(100)) и execute(() => pay(200))
  /// будут считаться одинаковыми — второй получит результат первого
  /// (или cancelled при shareWithOvertaken=false).
  exhaustMap,

  /// Запускает все вызовы параллельно и удерживает их в общем пуле.
  /// Значение — не в параллельности как таковой (её даёт сам Dart),
  /// а в групповом управлении жизненным циклом:
  /// cancelAll() и dispose() отменяют все активные операции разом,
  /// обрывая их HTTP-запросы через CancelToken.
  ///
  /// Типичный кейс: набор независимых загрузок в рамках одного экрана
  /// или BLoC (профиль + лента + уведомления). При уходе с экрана
  /// один вызов dispose() завершает всё.
  ///
  /// Флаг shareWithOvertaken на эту стратегию не влияет.
  mergeMap,

  /// Выполняет вызовы строго по очереди — каждый следующий стартует
  /// только после завершения (или отмены) предыдущего.
  /// Типичные кейсы: последовательная запись в файл/БД, операции,
  /// где важен порядок применения.
  ///
  /// Новые вызовы во время активной операции встают в очередь
  /// (состояние inQueue у item). При cancelAll() очередь тоже
  /// очищается — все ожидающие получают cancelled.
  ///
  /// Флаг shareWithOvertaken на эту стратегию не влияет.
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
    void Function(ConcurrencyExecutorItem<T> executor)? onDone,
    void Function(ConcurrencyExecutorItem<T> executor)? onStart,
    required ConcurrencyExecutorHandler<T> handler,
    CancelToken? cancelToken,
  })  : _onDone = onDone,
        _onStart = onStart,
        _handler = handler {
    this.cancelToken = (cancelToken ?? CancelToken());
    this.cancelToken.whenCancel.then(
      (value) {
        if (!awaitingReplacement) {
          cancel();
        }
      },
    );
  }

  final int id;
  final void Function(ConcurrencyExecutorItem<T> executor)? _onDone;
  final void Function(ConcurrencyExecutorItem<T> executor)? _onStart;
  final FlexibleCompleter<ConcurrencyExecutorResult<T>> _completer =
      FlexibleCompleter();
  late final CancelToken cancelToken;
  final ConcurrencyExecutorHandler<T> _handler;
  bool _started = false;
  bool _awaitingReplacement = false;

  bool get isCompleted => _completer.isCompleted;

  bool get isProcessing => _started && !isCompleted;

  bool get inQueue => !isCompleted && !_started;

  bool get awaitingReplacement => _awaitingReplacement;

  bool get isCancelled {
    final value = _completer.value;
    if (value == null) {
      return false;
    }
    return value.isCancelled;
  }

  void _markAsAwaitingReplacement() {
    _awaitingReplacement = true;
    cancelToken.tryCancel();
  }

  Future<ConcurrencyExecutorResult<T>> get future => _completer.future;

  ConcurrencyExecutorResult<T>? get result => _completer.value;

  void _complete(OperationResult<T> result) {
    if (!isCompleted) {
      _awaitingReplacement = false;
      _completer.complete(
        ConcurrencyExecutorResult.success(id, result),
      );
      _onDone?.call(this);
    }
  }

  Future<void> _start() async {
    if (isCompleted || _started) return;
    _started = true;
    _onStart?.call(this);
    if (_awaitingReplacement) return;
    final result = await _handler(this).safeExecute();
    if (!_awaitingReplacement) {
      _complete(result);
    }
  }

  void cancel() {
    if (isCompleted || isCancelled) {
      return;
    }
    _awaitingReplacement = false;
    cancelToken.tryCancel();
    _completer.complete(ConcurrencyExecutorResult.cancelled(id));
    _onDone?.call(this);
  }
}

/// Оркестратор конкурентных async-операций с гибкими стратегиями
/// и интеграцией с [CancelToken] из Dio.
///
/// Пример (поиск):
/// ```dart
/// final executor = ConcurrencyExecutor<List<User>>(
///   strategy: ConcurrencyExecutorStrategy.switchMap,
/// );
///
/// Future<void> onSearchChanged(String query) async {
///   final result = await executor.execute(
///     (item) => api.searchUsers(query, cancelToken: item.cancelToken),
///   );
///   result.when(
///     onSuccess: (r) => emit(state.copyWith(users: r.result)),
///     onCancelled: (_) {}, // устарел — игнорируем
///   );
/// }
///
/// @override
/// void close() {
///   executor.dispose();
///   super.close();
/// }
/// ```
class ConcurrencyExecutor<T> {
  ConcurrencyExecutor({
    this.strategy = ConcurrencyExecutorStrategy.switchMap,
    this.shareWithOvertaken = true,
  });

  /// Управляет поведением при конкурирующих вызовах.
  ///
  /// Влияет только на стратегии [switchMap] и [exhaustMap] —
  /// [mergeMap] и [concatMap] это поле игнорируют.
  ///
  /// - [switchMap] + shareWithOvertaken=true: предыдущие вызовы дожидаются
  ///   результата последнего handler'а и получают его же
  ///   (успех → success, отмена → cancelled). Отменённый токен
  ///   предыдущих позволяет Dio прервать их HTTP-запросы, но
  ///   вызывающие не видят cancelled — они видят актуальный результат.
  ///
  /// - [switchMap] + shareWithOvertaken=false: предыдущие вызовы сразу
  ///   получают cancelled, новый запускается независимо.
  ///
  /// - [exhaustMap] + shareWithOvertaken=true: новый вызов во время активного
  ///   получает Future текущей операции (дедупликация).
  ///
  /// - [exhaustMap] + shareWithOvertaken=false: новый вызов во время активного
  ///   сразу получает cancelled, текущая операция продолжается.
  final bool shareWithOvertaken;
  final ConcurrencyExecutorStrategy strategy;
  final IntGenerator _idGenerator = IntGenerator();
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
      _executorMap[id]?.cancel();
    } else {
      final items = _executorMap.values.toList();
      for (final item in items) {
        item.cancel();
      }
    }
  }

  ConcurrencyExecutorItem<T>? findExecutorById(int id) {
    return _executorMap[id];
  }

  void _onExecutorDone(ConcurrencyExecutorItem<T> executor) {
    final id = executor.id;
    _executorMap.remove(id);
    if (_executorMap.isNotEmpty) {
      if (strategy == ConcurrencyExecutorStrategy.concatMap) {
        final next = _executorMap.entries.first.value;
        if (next.inQueue) {
          next._start();
        }
      } else if ([
            ConcurrencyExecutorStrategy.exhaustMap,
            ConcurrencyExecutorStrategy.switchMap
          ].contains(strategy) &&
          shareWithOvertaken &&
          !executor.awaitingReplacement) {
        final result = executor.result;
        if (result != null) {
          while (_executorMap.isNotEmpty) {
            final takeLast = strategy == ConcurrencyExecutorStrategy.switchMap;
            final item = takeLast
                ? _executorMap.entries.last.value
                : _executorMap.entries.first.value;
            result.when(
              onSuccess: (result) {
                item._complete(result.result);
              },
              onCancelled: (result) {
                item.cancel();
              },
            );
          }
        }
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
    var markAsWaiting = false;
    switch (strategy) {
      case ConcurrencyExecutorStrategy.concatMap:
      case ConcurrencyExecutorStrategy.mergeMap:
        break;
      case ConcurrencyExecutorStrategy.exhaustMap:
        if (shareWithOvertaken) {
          if (isProcessing) {
            markAsWaiting = true;
          }
        } else {
          if (isProcessing) {
            needCancel = true;
          }
        }
        break;
      case ConcurrencyExecutorStrategy.switchMap:
        if (shareWithOvertaken) {
          for (final entry in _executorMap.entries) {
            entry.value._markAsAwaitingReplacement();
          }
        } else {
          cancelAll();
        }
        break;
    }

    final id = _idGenerator.generate();
    final executorItem = ConcurrencyExecutorItem<T>(
      id: id,
      handler: handler,
      onStart: (item) => onStart?.call(id),
      onDone: (item) => _onExecutorDone(item),
    );
    if (markAsWaiting) {
      executorItem._markAsAwaitingReplacement();
    }
    final skipConcat =
        strategy == ConcurrencyExecutorStrategy.concatMap && isProcessing;
    final skip = skipConcat;
    final autoStart = !skip;
    if (needCancel) {
      executorItem.cancel();
    } else {
      if (autoStart) {
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
