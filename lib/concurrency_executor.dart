import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_toolkit/flutter_toolkit.dart';

/// Расширение [CancelToken] для безопасной отмены без проверок и try/catch.
///
/// Стандартный `cancel()` принтит в консоль ошибку при повторном вызове.
/// `tryCancel` инкапсулирует проверку `isCancelled` и обработку ошибок,
/// возвращая bool: true — отмена прошла, false — токен уже был отменён
/// или произошла ошибка.
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

/// Стратегия обработки конкурирующих вызовов в [ConcurrencyExecutor].
///
/// Названия и семантика заимствованы из RxDart/RxJS операторов того же
/// назначения, но применены к императивному API через [Future].
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
  /// (включая callbacks onComplete/onCancelled). Item дублирующего вызова
  /// помечается как awaitingReplacement и его handler не запускается,
  /// но onStart всё равно срабатывает — используйте item.awaitingReplacement
  /// чтобы различать реальный старт и ожидание чужого результата.
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

/// Сигнатура handler'а — асинхронной операции, которую исполняет executor.
///
/// Получает [ConcurrencyExecutorItem] для доступа к контексту вызова
/// (cancelToken, id, состояние). Должен возвращать Future с результатом
/// типа T. Брошенные исключения перехватываются через safeExecute()
/// и оборачиваются в OperationResult.error.
typedef ConcurrencyExecutorHandler<T> = Future<T> Function(
  ConcurrencyExecutorItem handler,
);

/// Колбэк "операция стартовала".
///
/// Вызывается при первом запуске handler'а или при попытке запуска
/// awaiting item'а (тогда handler не выполнится, но onStart сработает).
/// Полезен для отображения индикаторов загрузки.
typedef OnConcurrencyExecutorStart = void Function(int id);

/// Колбэк завершения операции (success или error).
///
/// Срабатывает ВМЕСТЕ с [OnConcurrencyExecutorSuccessResult] (для success)
/// или [OnConcurrencyExecutorErrorResult] (для error) — это два уровня
/// одного события: общий и детальный. Подписывайтесь на тот уровень,
/// который удобнее.
///
/// `shared = true` означает что вызов был помечен как awaitingReplacement
/// и получил результат другой операции, а не результат своего handler'а.
typedef OnConcurrencyExecutorComplete<T> = void Function(
  int id,
  ConcurrencyExecutorCompleteResult<T> result,
  bool shared,
);

/// Колбэк отмены операции.
///
/// Вызывается когда item получил cancelled результат — через явный
/// cancel(), cancelAll(), dispose(), или при cascade-отмене из
/// awaiting состояния.
typedef OnConcurrencyExecutorCancelled<T> = void Function(
  int id,
  ConcurrencyExecutorCancelledResult<T> result,
  bool shared,
);

/// Колбэк успешного завершения с распакованным значением.
///
/// Срабатывает ВМЕСТЕ с [OnConcurrencyExecutorComplete] — детальный
/// уровень того же события. Удобен когда нужно сразу работать со
/// значением T без распаковки OperationResult.
typedef OnConcurrencyExecutorSuccessResult<T> = void Function(
  int id,
  T result,
  bool shared,
);

/// Колбэк ошибки с распакованным error/stackTrace.
///
/// Срабатывает ВМЕСТЕ с [OnConcurrencyExecutorComplete] — детальный
/// уровень того же события для случая когда внутри OperationResult — error.
typedef OnConcurrencyExecutorErrorResult = void Function(
  int id,
  Object error,
  StackTrace stackTrace,
  bool shared,
);

/// Результат вызова [ConcurrencyExecutor.execute].
///
/// Sealed-иерархия из двух состояний:
/// - [ConcurrencyExecutorCompleteResult] — handler завершился (успех или ошибка)
/// - [ConcurrencyExecutorCancelledResult] — операция отменена
///
/// Используйте [when] для exhaustive-обработки или [map] для опциональной.
sealed class ConcurrencyExecutorResult<T> with EquatableMixin {
  const ConcurrencyExecutorResult(this.id);

  /// Идентификатор вызова, выданный [ConcurrencyExecutor] в execute().
  /// Уникален в рамках одного executor'а.
  final int id;

  const factory ConcurrencyExecutorResult.cancelled(
    int id, [
    OperationResult<T>? result,
  ]) = ConcurrencyExecutorCancelledResult;

  const factory ConcurrencyExecutorResult.complete(
    int id,
    OperationResult<T> result,
  ) = ConcurrencyExecutorCompleteResult;

  /// true если результат — cancelled.
  bool get isCancelled {
    return map(
          onCancelled: (result) => true,
        ) ??
        false;
  }

  /// true если результат — complete (success или error внутри OperationResult).
  bool get isComplete {
    return map(
          onComplete: (result) => true,
        ) ??
        false;
  }

  /// Exhaustive-сопоставление по типу результата.
  /// Оба колбэка обязательны — компилятор гарантирует покрытие всех случаев.
  WhenValue when<WhenValue>({
    required WhenValue Function(ConcurrencyExecutorCompleteResult<T> result)
        onComplete,
    required WhenValue Function(ConcurrencyExecutorCancelledResult<T> result)
        onCancelled,
  }) {
    final result = this;
    return switch (result) {
      ConcurrencyExecutorCancelledResult<T> _ => onCancelled(result),
      ConcurrencyExecutorCompleteResult<T> _ => onComplete(result),
    };
  }

  /// Опциональное сопоставление с двумя уровнями детализации:
  /// - onComplete/onCancelled — общий уровень (тип результата)
  /// - onSuccessResult/onErrorResult — детальный уровень (распакованный OperationResult)
  ///
  /// onComplete и onSuccessResult/onErrorResult вызываются ВМЕСТЕ для
  /// одного complete-результата. Возвращается значение детального колбэка
  /// (если он передан и вернул не null), иначе общего.
  MapValue? map<MapValue>({
    MapValue? Function(ConcurrencyExecutorCompleteResult<T> result)? onComplete,
    MapValue? Function(ConcurrencyExecutorCancelledResult<T> result)?
        onCancelled,
    MapValue? Function(int id, T result)? onSuccessResult,
    MapValue? Function(int id, Object error, StackTrace stackTrace)?
        onErrorResult,
  }) {
    return when(
      onComplete: (result) {
        final completeResultValue = onComplete?.call(result);
        final operationResultValue = result.result.map(
          onSuccess: (result) {
            return onSuccessResult?.call(id, result);
          },
          onError: (error, stackTrace) {
            return onErrorResult?.call(id, error, stackTrace);
          },
        );
        return operationResultValue ?? completeResultValue;
      },
      onCancelled: (result) => onCancelled?.call(result),
    );
  }

  @override
  List<Object?> get props => [id];
}

/// Результат отменённого вызова.
///
/// Опциональный [result] хранит частичное состояние OperationResult,
/// если оно было до отмены — например, при cascade-отмене через
/// замещающий вызов с cancelled результатом.
class ConcurrencyExecutorCancelledResult<T>
    extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorCancelledResult(super.id, [this.result]);

  final OperationResult<T>? result;

  @override
  List<Object?> get props => [...super.props, result];
}

/// Результат завершённого вызова — содержит OperationResult с success или error.
class ConcurrencyExecutorCompleteResult<T>
    extends ConcurrencyExecutorResult<T> {
  const ConcurrencyExecutorCompleteResult(super.id, this.result);

  final OperationResult<T> result;

  @override
  List<Object?> get props => [...super.props, result];
}

/// Группирует callbacks для уведомлений о состоянии операций executor'а.
///
/// Используется на двух уровнях:
/// - Глобально через [ConcurrencyExecutor.callbacks] — срабатывает для
///   всех операций executor'а (удобно для аналитики, логирования)
/// - Локально через параметр [ConcurrencyExecutor.execute] — срабатывает
///   только для конкретного вызова (UI-логика, side effects экрана)
///
/// При наличии обоих уровней порядок вызова: сначала глобальные, потом локальные.
///
/// **Семантика onComplete vs onSuccessResult/onErrorResult:**
/// onComplete — общее уведомление о завершении.
/// onSuccessResult/onErrorResult — детальная развёртка того же события
/// с распакованным значением T или error+stackTrace.
/// Вызываются ВМЕСТЕ для одного complete-результата. Подписывайтесь
/// на удобный уровень детализации, либо на оба сразу.
///
/// **Семантика shared результата:**
/// Колбэк получает параметр `shared` — true если вызов был помечен
/// awaitingReplacement и получил результат другой операции (см.
/// [ConcurrencyExecutorItem.wasMarkedForReplacement]).
///
/// **Семантика [notifyOnSharedResult]:**
/// По умолчанию false — для shared результатов колбэки подавляются,
/// чтобы избежать дублирования side effects (диалоги, навигация).
/// См. документацию поля.
class ConcurrencyExecutorCallbacks<T> {
  const ConcurrencyExecutorCallbacks({
    this.onStart,
    this.onCancelled,
    this.onComplete,
    this.onErrorResult,
    this.onSuccessResult,
    this.notifyOnSharedResult = false,
  });

  /// Контролирует вызов колбэков для shared результатов и shared старта.
  ///
  /// Shared — когда вызов был помечен как awaitingReplacement
  /// и взаимодействует с результатом другой операции:
  /// - switchMap + shareWithOvertaken: предыдущие вызовы получают результат нового
  /// - exhaustMap + shareWithOvertaken: дублирующие вызовы получают результат активного
  ///
  /// **Default: false** — чтобы избежать дублирования side effects.
  /// Если 5 пользовательских вызовов получили один результат, обычно
  /// нежелательно дёргать onComplete/onSuccessResult 5 раз
  /// (например, 5 раз показывать диалог "успешно").
  ///
  /// При false: колбэки сработают только если handler этого вызова
  /// завершился сам. Future при этом всё равно резолвится с результатом
  /// для всех вызывающих — но колбэки тихие.
  ///
  /// При true: колбэки срабатывают для каждого вызова, включая shared.
  /// Полезно для аналитики/логирования, где важно отследить каждый
  /// вызов отдельно.
  ///
  /// **Внимание:** этот флаг применяется ко ВСЕМ колбэкам, включая onStart.
  /// Для exhaust-waiter'ов это означает что onStart подавляется при default
  /// настройке — спиннер на UI для дублирующих вызовов нужно показывать
  /// другим способом (например через состояние Future).
  final bool notifyOnSharedResult;

  /// Колбэк старта операции. Подчиняется [notifyOnSharedResult] —
  /// для shared старта (exhaust-waiter с shareWithOvertaken) подавляется
  /// при notifyOnSharedResult=false.
  final OnConcurrencyExecutorStart? onStart;

  /// Колбэк отмены операции. Подчиняется [notifyOnSharedResult].
  final OnConcurrencyExecutorCancelled<T>? onCancelled;

  /// Колбэк завершения (success или error). Срабатывает ВМЕСТЕ с
  /// [onSuccessResult]/[onErrorResult]. Подчиняется [notifyOnSharedResult].
  final OnConcurrencyExecutorComplete<T>? onComplete;

  /// Колбэк ошибки с распакованным error/stackTrace. Срабатывает ВМЕСТЕ
  /// с [onComplete]. Подчиняется [notifyOnSharedResult].
  final OnConcurrencyExecutorErrorResult? onErrorResult;

  /// Колбэк успеха с распакованным значением T. Срабатывает ВМЕСТЕ
  /// с [onComplete]. Подчиняется [notifyOnSharedResult].
  final OnConcurrencyExecutorSuccessResult<T>? onSuccessResult;

  /// Универсальный guard для всех уведомлений: пропускает callback только
  /// если результат не shared, либо если notifyOnSharedResult=true.
  /// Единая точка контроля для onStart и всех result-колбэков.
  void _notify(
      ConcurrencyExecutorItem<T> item, void Function(bool shared) callback) {
    final shared = item.wasMarkedForReplacement;
    if (notifyOnSharedResult || !shared) {
      callback(shared);
    }
  }

  /// Уведомляет о старте операции с учётом shared-фильтра.
  void _notifyStart(ConcurrencyExecutorItem<T> item) {
    _notify(
      item,
      (shared) {
        onStart?.call(item.id);
      },
    );
  }

  /// Уведомляет о результате операции с учётом shared-фильтра.
  ///
  /// Раскладывает результат через map(): для complete-случая срабатывают
  /// onComplete + (onSuccessResult или onErrorResult в зависимости от
  /// содержимого OperationResult), для cancelled — onCancelled.
  void _notifyResult({
    required ConcurrencyExecutorResult<T> result,
    required ConcurrencyExecutorItem<T> item,
  }) {
    _notify(
      item,
      (shared) {
        result.map(
          onErrorResult: (id, error, stackTrace) {
            onErrorResult?.call(id, error, stackTrace, shared);
          },
          onSuccessResult: (id, result) {
            onSuccessResult?.call(id, result, shared);
          },
          onComplete: (result) {
            onComplete?.call(result.id, result, shared);
          },
          onCancelled: (result) {
            onCancelled?.call(result.id, result, shared);
          },
        );
      },
    );
  }
}

/// Единица работы внутри [ConcurrencyExecutor] — обёртка над одним
/// вызовом execute().
///
/// Хранит handler, состояние выполнения, [cancelToken] для интеграции
/// с Dio и Future с результатом. Управляется executor'ом — пользователь
/// не создаёт экземпляры напрямую.
///
/// Жизненный цикл:
/// 1. Создан в execute() — `inQueue == true` (для concatMap waiter'ов
///    и пока не вызван _start)
/// 2. _start() вызван — `isProcessing == true`, handler выполняется
/// 3. _complete()/cancel() — `isCompleted == true`, future резолвлен
///
/// Особое состояние awaitingReplacement: item помечен на получение
/// чужого результата (см. [awaitingReplacement] и [wasMarkedForReplacement]).
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
    // Если cancelToken отменён извне — конвертируем это в cancel item'а.
    // Защита `if (!awaitingReplacement)` предотвращает самоотмену когда
    // токен был отменён внутренним механизмом _markAsAwaitingReplacement.
    this.cancelToken.whenCancel.then(
      (value) {
        if (!awaitingReplacement) {
          cancel();
        }
      },
    );
  }

  /// Уникальный идентификатор в рамках executor'а.
  final int id;

  final void Function(ConcurrencyExecutorItem<T> executor)? _onDone;
  final void Function(ConcurrencyExecutorItem<T> executor)? _onStart;
  final FlexibleCompleter<ConcurrencyExecutorResult<T>> _completer =
      FlexibleCompleter();

  /// Токен отмены для интеграции с Dio. Передавайте его в HTTP-запросы
  /// внутри handler'а — при cancel/cancelAll/dispose Dio прервёт
  /// сетевой запрос на нижнем уровне.
  late final CancelToken cancelToken;

  final ConcurrencyExecutorHandler<T> _handler;
  bool _started = false;
  bool _awaitingReplacement = false;
  bool _wasMarkedForReplacement = false;

  /// true когда item полностью завершён (complete или cancelled).
  bool get isCompleted => _completer.isCompleted;

  /// true если item когда-либо был помечен awaitingReplacement.
  ///
  /// В отличие от [awaitingReplacement], этот флаг НЕ сбрасывается
  /// после получения результата — он отражает историю item'а.
  /// Используется callbacks-системой для определения shared-результата:
  /// если item был помечен → его результат пришёл от другой операции →
  /// shared = true.
  bool get wasMarkedForReplacement => _wasMarkedForReplacement;

  /// true когда _start() был вызван и item ещё не завершён.
  ///
  /// Внимание: для exhaustMap+shareWithOvertaken дублирующего вызова
  /// возвращает true даже если handler фактически не запущен —
  /// item ждёт результат активной операции. Чтобы различать
  /// "handler работает" и "item ждёт чужой результат" используйте
  /// [awaitingReplacement].
  bool get isProcessing => _started && !isCompleted;

  /// true когда item ещё не стартовал (актуально для concatMap —
  /// item стоит в очереди и ждёт завершения предыдущего).
  bool get inQueue => !isCompleted && !_started;

  /// true когда item ждёт результат другой операции вместо запуска
  /// собственного handler'а.
  ///
  /// Возникает в двух случаях:
  /// - switchMap+shareWithOvertaken: предыдущий item помечается awaiting
  ///   при появлении нового вызова и ждёт его результат
  /// - exhaustMap+shareWithOvertaken: новый item помечается awaiting
  ///   при наличии активной операции и ждёт её результат
  ///
  /// Когда item awaiting:
  /// - его handler не вызывается
  /// - его cancelToken отменён (чтобы прервать сетевой запрос если был)
  /// - он остаётся в map executor'а до получения результата извне
  ///
  /// Сбрасывается в false после получения результата (success/cancel).
  /// Если нужна история "был ли когда-либо помечен" — используйте
  /// [wasMarkedForReplacement].
  bool get awaitingReplacement => _awaitingReplacement;

  /// true если item завершён cancelled-результатом.
  /// Возвращает false для незавершённых items и для complete-результатов.
  bool get isCancelled {
    final value = _completer.value;
    if (value == null) {
      return false;
    }
    return value.isCancelled;
  }

  /// Внутренний метод для пометки item'а как ожидающего замены.
  ///
  /// Вызывается executor'ом при switchMap (для предыдущих) и
  /// exhaustMap (для новых дубликатов). Отменяет cancelToken
  /// чтобы прервать активный сетевой запрос, но не завершает Future —
  /// item ждёт что executor вызовет _complete() с чужим результатом.
  void _markAsAwaitingReplacement() {
    if (isCompleted) return;
    _awaitingReplacement = true;
    _wasMarkedForReplacement = true;
    cancelToken.tryCancel();
  }

  /// Future с результатом операции. Резолвится после завершения handler'а
  /// или после получения чужого результата (для awaiting items).
  Future<ConcurrencyExecutorResult<T>> get future => _completer.future;

  /// Текущее значение результата если item уже завершён, иначе null.
  ConcurrencyExecutorResult<T>? get result => _completer.value;

  /// Завершает item с success-результатом. Используется как для
  /// собственного завершения handler'а, так и для cascade-передачи
  /// чужого результата от executor'а (см. [ConcurrencyExecutor._onExecutorDone]).
  void _complete(OperationResult<T> result) {
    if (!isCompleted) {
      _awaitingReplacement = false;
      _completer.complete(
        ConcurrencyExecutorResult.complete(id, result),
      );
      _onDone?.call(this);
    }
  }

  /// Запускает обработку item'а.
  ///
  /// Для awaiting items (помечены до вызова _start) handler НЕ запускается,
  /// но onStart callback всё равно срабатывает — это позволяет UI
  /// показать индикатор загрузки даже для дублирующих exhaust вызовов.
  /// Если в onStart нужно различать реальный старт от ожидания —
  /// проверяйте item.awaitingReplacement.
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

  /// Отменяет item.
  ///
  /// Завершает Future с cancelled-результатом, отменяет cancelToken
  /// (что прервёт активный HTTP-запрос Dio). После cancel'а повторные
  /// вызовы — no-op.
  ///
  /// Сбрасывает _awaitingReplacement — отменённый item больше не ждёт
  /// чужой результат.
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
/// Поддерживает четыре стратегии обработки конкурирующих вызовов
/// (см. [ConcurrencyExecutorStrategy]) и единый dispose-цикл для
/// массовой отмены всех активных операций.
///
/// Дженерик по T — один executor работает с одним типом результата.
/// Для разных типов создавайте отдельные executors.
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
///     onComplete: (r) => emit(state.copyWith(users: r.result)),
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
    ConcurrencyExecutorCallbacks<T>? callbacks,
  }) : callbacks = callbacks ?? ConcurrencyExecutorCallbacks<T>();

  /// Управляет поведением при конкурирующих вызовах.
  ///
  /// Влияет только на стратегии [ConcurrencyExecutorStrategy.switchMap]
  /// и [ConcurrencyExecutorStrategy.exhaustMap] —
  /// [ConcurrencyExecutorStrategy.mergeMap] и
  /// [ConcurrencyExecutorStrategy.concatMap] это поле игнорируют.
  ///
  /// - switchMap + shareWithOvertaken=true: предыдущие вызовы дожидаются
  ///   результата последнего handler'а и получают его же
  ///   (успех → complete, отмена → cancelled). Отменённый токен
  ///   предыдущих позволяет Dio прервать их HTTP-запросы, но
  ///   вызывающие не видят cancelled — они видят актуальный результат.
  ///
  /// - switchMap + shareWithOvertaken=false: предыдущие вызовы сразу
  ///   получают cancelled, новый запускается независимо.
  ///
  /// - exhaustMap + shareWithOvertaken=true: новый вызов во время активного
  ///   получает Future текущей операции (дедупликация). Item нового вызова
  ///   помечается awaitingReplacement, его handler не запускается, но
  ///   onStart callback всё равно срабатывает (для индикаторов загрузки).
  ///
  /// - exhaustMap + shareWithOvertaken=false: новый вызов во время активного
  ///   сразу получает cancelled, текущая операция продолжается.
  final bool shareWithOvertaken;

  /// Стратегия обработки конкурирующих вызовов.
  /// См. [ConcurrencyExecutorStrategy] для описания каждого варианта.
  final ConcurrencyExecutorStrategy strategy;

  /// SplayTreeMap по id для упорядоченного итерирования (first/last).
  /// Порядок важен в _onExecutorDone: для switchMap раздаём результат
  /// с last (самый новый), для exhaustMap — с first (самый старый ждущий).
  final SplayTreeMap<int, ConcurrencyExecutorItem<T>> _executorMap =
      SplayTreeMap();
  bool _disposed = false;

  /// Глобальные колбэки уровня executor'а — срабатывают для всех
  /// операций. Удобно для аналитики/логирования.
  /// При наличии локальных колбэков (через [execute]) глобальные
  /// вызываются первыми.
  final ConcurrencyExecutorCallbacks<T> callbacks;

  final IntGenerator _idGenerator = IntGenerator();

  /// true когда есть хотя бы одна активная операция в пуле.
  /// Активные = всё что в _executorMap (выполняющиеся, awaiting, в очереди).
  bool get isProcessing {
    return _executorMap.isNotEmpty;
  }

  /// Закрывает executor — отменяет все активные операции и блокирует
  /// дальнейшие execute() (новые вызовы сразу получат cancelled).
  ///
  /// Идемпотентен. Обычно вызывается из dispose()/close() владельца —
  /// BLoC, контроллера, ViewModel.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll();
  }

  /// Отменяет все активные операции одновременно.
  /// Каждый item получит cancelled-результат, сетевые запросы Dio
  /// прервутся через CancelToken.
  void cancelAll() {
    return _cancel();
  }

  /// Отменяет конкретную операцию по id (выданному в execute()).
  void cancelById(int id) {
    return _cancel(id: id);
  }

  void _cancel({int? id}) {
    if (id != null) {
      _executorMap[id]?.cancel();
    } else {
      // Снимок списка — необходим, потому что cancel() триггерит _onDone,
      // который удаляет item из _executorMap, и мы не можем
      // итерировать по изменяющейся коллекции.
      final items = _executorMap.values.toList();
      for (final item in items) {
        item.cancel();
      }
    }
  }

  /// Возвращает item по id или null если такого нет в активном пуле.
  /// Полезно для проверки состояния конкретного вызова или для
  /// принудительной отмены через item.cancel().
  ConcurrencyExecutorItem<T>? findExecutorById(int id) {
    return _executorMap[id];
  }

  /// Хук завершения item'а — вызывается из _complete()/cancel() через
  /// _onDone callback.
  ///
  /// Делает три вещи:
  /// 1. Удаляет завершённый item из _executorMap
  /// 2. Для concatMap — стартует следующий из очереди
  /// 3. Для switchMap/exhaustMap с shareWithOvertaken — раздаёт результат
  ///    оставшимся awaiting items (cascade-передача)
  ///
  /// Cascade-направление: для switchMap берём `last` (самые новые
  /// awaiting в конце), для exhaustMap — `first` (самые старые ждут
  /// дольше всех).
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
              onComplete: (result) {
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

  /// Запускает асинхронную операцию через executor.
  ///
  /// Поведение зависит от [strategy] и [shareWithOvertaken] —
  /// см. документацию полей и описание стратегий в
  /// [ConcurrencyExecutorStrategy].
  ///
  /// Возвращаемый Future всегда резолвится с [ConcurrencyExecutorResult] —
  /// никогда не бросает. Ошибки handler'а попадают внутрь
  /// [ConcurrencyExecutorCompleteResult] через OperationResult.error.
  ///
  /// [callbacks] — локальные колбэки для конкретного вызова. Срабатывают
  /// после глобальных (executor-level). См. [ConcurrencyExecutorCallbacks]
  /// и [ConcurrencyExecutorCallbacks.notifyOnSharedResult] для деталей
  /// фильтрации shared-результатов.
  Future<ConcurrencyExecutorResult<T>> execute(
    ConcurrencyExecutorHandler<T> handler, {
    ConcurrencyExecutorCallbacks<T>? callbacks,
  }) async {
    final localCallbacks = callbacks ?? ConcurrencyExecutorCallbacks<T>();
    var needCancel = _disposed;
    var markAsWaiting = false;
    switch (strategy) {
      case ConcurrencyExecutorStrategy.concatMap:
      case ConcurrencyExecutorStrategy.mergeMap:
        // Эти стратегии не реагируют на наличие активных операций
        // на этапе принятия — concatMap встанет в очередь через autoStart=false,
        // mergeMap запустится параллельно.
        break;
      case ConcurrencyExecutorStrategy.exhaustMap:
        if (shareWithOvertaken) {
          if (isProcessing) {
            // Дублирующий вызов: помечаем как awaiting, он получит
            // результат активной операции через cascade в _onExecutorDone.
            markAsWaiting = true;
          }
        } else {
          if (isProcessing) {
            // Без sharing — дублирующий вызов сразу cancelled,
            // активная операция продолжается без изменений.
            needCancel = true;
          }
        }
        break;
      case ConcurrencyExecutorStrategy.switchMap:
        if (shareWithOvertaken) {
          // Помечаем все предыдущие как awaiting — они получат результат
          // нового вызова через cascade. Их handler'ы прерываются через
          // отменённый CancelToken, но Future остаётся живым.
          for (final entry in _executorMap.entries) {
            entry.value._markAsAwaitingReplacement();
          }
        } else {
          // Без sharing — предыдущие сразу получают cancelled.
          cancelAll();
        }
        break;
    }

    final id = _idGenerator.generate();
    final executorItem = ConcurrencyExecutorItem<T>(
      id: id,
      handler: handler,
      onStart: (item) {
        // Сначала глобальные колбэки, потом локальные.
        // Каждый _notifyStart применяет фильтр notifyOnSharedResult
        // к своему уровню колбэков.
        this.callbacks._notifyStart(item);
        localCallbacks._notifyStart(item);
      },
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
      // Для disposed executor или exhaust+!sharing — item сразу cancelled
      // и НЕ попадает в _executorMap. Future уже завершён cancelled.
      executorItem.cancel();
    } else {
      if (autoStart) {
        executorItem._start();
      }
      // Не-стартующие (concat в очереди) и стартующие добавляются в map.
      _executorMap[id] = executorItem;
    }
    final future = executorItem.future;
    // Уведомление о результате после резолва Future.
    // Порядок: глобальные → локальные. Каждый уровень сам применяет
    // shared-фильтр через _notifyResult.
    future.then(
      (result) {
        this.callbacks._notifyResult(result: result, item: executorItem);
        localCallbacks._notifyResult(result: result, item: executorItem);
      },
    );
    return future;
  }
}
