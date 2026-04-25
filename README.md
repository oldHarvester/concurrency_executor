# concurrency_executor

A Flutter package for orchestrating concurrent async operations with flexible execution strategies and built-in [Dio](https://pub.dev/packages/dio) `CancelToken` integration.

Instead of manually managing race conditions, duplicate requests, and cancellation logic, you declare *how* concurrent calls should behave and the executor handles the rest.

## Features

- **4 execution strategies** — switchMap, exhaustMap, mergeMap, concatMap
- **Dio CancelToken integration** — HTTP requests are aborted automatically when an operation is cancelled
- **Result sharing** — overtaken callers can receive the latest result instead of a cancellation
- **Lifecycle management** — `cancelAll()` and `dispose()` cancel every active operation at once
- **Type-safe results** — sealed `ConcurrencyExecutorResult<T>` with `when()` / `map()` for exhaustive handling

## Installation

This package depends on a private Git package. Add both to your `pubspec.yaml`:

```yaml
dependencies:
  concurrency_executor:
    git:
      url: https://github.com/<your-org>/concurrency_executor.git
  flutter_toolkit:
    git:
      url: https://github.com/oldHarvester/flutter_toolkit.git
  dio: ">=5.0.0 <7.0.0"
```

## Strategies

### switchMap — always the latest result

Cancels any running operation and starts a new one. Use for search inputs, filters, and autocomplete where only the newest result matters.

```dart
final searchExecutor = ConcurrencyExecutor<List<User>>(
  strategy: ConcurrencyExecutorStrategy.switchMap,
);

Future<void> onSearchChanged(String query) async {
  final result = await searchExecutor.execute(
    (item) => api.searchUsers(query, cancelToken: item.cancelToken),
  );
  result.when(
    onComplete: (r) => setState(() => users = r.result.asSuccess),
    onCancelled: (_) {}, // query was superseded — ignore
  );
}
```

**`shareWithOvertaken: true` (default)** — previous callers wait for the latest result and receive it as their own. Their HTTP requests are still cancelled via `CancelToken`, but they never see a `cancelled` outcome.

**`shareWithOvertaken: false`** — previous callers receive `cancelled` immediately.

---

### exhaustMap — deduplicate concurrent calls

While an operation is running, additional calls do not start a new handler. Use for payment buttons, form submissions, and any action that must not run twice simultaneously.

```dart
final submitExecutor = ConcurrencyExecutor<Order>(
  strategy: ConcurrencyExecutorStrategy.exhaustMap,
);

Future<void> onSubmitPressed() async {
  final result = await submitExecutor.execute(
    (item) => api.submitOrder(cart, cancelToken: item.cancelToken),
    onStart: (id) => showSpinner(),
    onComplete: (r) => hideSpinner(),
  );
  result.map(
    onSuccessResult: (id, order) => navigateToConfirmation(order),
    onErrorResult: (id, error, _) => showErrorBanner(error),
    onCancelled: (_) {}, // already running — this call is ignored
  );
}
```

**`shareWithOvertaken: true` (default)** — duplicate calls receive the same `Future` as the active operation (true deduplication). The duplicate item is marked `awaitingReplacement`; its `onStart` callback still fires so you can show a loading indicator.

**`shareWithOvertaken: false`** — duplicate calls receive `cancelled` immediately; the active operation continues unaffected.

> **Note:** deduplication is by the *fact* of an active operation, not by handler arguments. `execute(() => pay(100))` and `execute(() => pay(200))` are treated as duplicates — the second call receives the result of the first.

---

### mergeMap — grouped parallel operations

Runs all calls concurrently without any cancellation between them. The value is centralized lifecycle control: `cancelAll()` and `dispose()` cancel every active operation at once, aborting their HTTP requests via `CancelToken`.

```dart
// In a BLoC / ViewModel — one executor for all screen loads
final screenExecutor = ConcurrencyExecutor<void>(
  strategy: ConcurrencyExecutorStrategy.mergeMap,
);

void loadScreen() {
  screenExecutor.execute((item) => loadProfile(item.cancelToken));
  screenExecutor.execute((item) => loadFeed(item.cancelToken));
  screenExecutor.execute((item) => loadNotifications(item.cancelToken));
}

@override
Future<void> close() {
  screenExecutor.dispose(); // cancels all three at once
  return super.close();
}
```

`shareWithOvertaken` has no effect on this strategy.

---

### concatMap — strict sequential execution

Each call starts only after the previous one completes (or is cancelled). Use for sequential file/database writes and any operations where order matters.

```dart
final writeExecutor = ConcurrencyExecutor<void>(
  strategy: ConcurrencyExecutorStrategy.concatMap,
);

// These will execute one after another, never in parallel
void onUserEditsField(String value) {
  writeExecutor.execute(
    (item) => db.saveField(value),
    onStart: (id) => print('writing $id'),
    onComplete: (r) => print('saved $id'),
  );
}
```

New calls that arrive while the executor is busy are queued — their item is marked `inQueue`. Calling `cancelAll()` drains the entire queue; all waiting items receive `cancelled`.

`shareWithOvertaken` has no effect on this strategy.

---

## Result handling

`execute()` returns `Future<ConcurrencyExecutorResult<T>>`. Use `when()` for exhaustive matching or `map()` for selective handling:

```dart
final result = await executor.execute((item) => fetchData(item.cancelToken));

// Exhaustive — must handle both branches
result.when(
  onComplete: (r) { /* r.result is OperationResult<T> */ },
  onCancelled: (_) {},
);

// Selective — handle only what you care about
result.map(
  onSuccessResult: (id, data) => updateUI(data),
  onErrorResult: (id, error, stackTrace) => logError(error),
  // onCancelled omitted — ignored
);
```

You can also pass callbacks directly to `execute()`:

```dart
await executor.execute(
  (item) => fetchData(item.cancelToken),
  onStart: (id) => showSpinner(),
  onSuccessResult: (id, data) => updateUI(data),
  onErrorResult: (id, error, _) => showError(error),
  onComplete: (r) => hideSpinner(),
  onCancelled: (r) => hideSpinner(),
);
```

---

## Lifecycle

```dart
// Cancel a specific operation by its ID
executor.cancelById(id);

// Cancel all active operations (queue is also cleared for concatMap)
executor.cancelAll();

// Cancel all and prevent future executions
executor.dispose();

// Check if any operation is running
if (executor.isProcessing) { ... }
```

---

## ConcurrencyExecutorItem

The `handler` callback receives a `ConcurrencyExecutorItem` which exposes:

| Property | Description |
|---|---|
| `id` | Unique integer identifier for this operation |
| `cancelToken` | Dio `CancelToken` — pass it to your HTTP calls |
| `isProcessing` | `true` if started and not yet finished |
| `isCompleted` | `true` if complete or cancelled |
| `inQueue` | `true` if waiting to start (concatMap only) |
| `awaitingReplacement` | `true` if waiting for another operation's result instead of running its own handler |

---

## Strategy quick reference

| Strategy | Behaviour | Use case |
|---|---|---|
| `switchMap` | Cancels previous, runs latest | Search, filters, autocomplete |
| `exhaustMap` | Ignores new calls while one is active | Payment button, form submit |
| `mergeMap` | Runs all in parallel | Independent screen loads |
| `concatMap` | Queues calls, runs in order | Sequential writes to file/DB |
