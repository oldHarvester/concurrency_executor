import 'package:concurrency_executor/concurrency_executor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_toolkit/flutter_toolkit.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) {
                        return ExamplePage();
                      },
                    ),
                  );
                },
                child: Text('Open'),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  final Map<ConcurrencyExecutorStrategy, ConcurrencyExecutor> _executorMap =
      Map.fromEntries(
        ConcurrencyExecutorStrategy.values.map(
          (strategy) {
            return MapEntry(
              strategy,
              ConcurrencyExecutor(strategy: strategy),
            );
          },
        ),
      );

  @override
  void dispose() {
    for (final entry in _executorMap.values) {
      entry.dispose();
    }
    super.dispose();
  }

  Widget buildStrategyTitle(ConcurrencyExecutorStrategy strategy) {
    return Text(
      strategy.name,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget buildButton({
    required String title,
    VoidCallback? onPressed,
  }) {
    return ElevatedButton(
      onPressed: onPressed,
      child: Text(title),
    );
  }

  Widget buildStrategyDescription(ConcurrencyExecutorStrategy strategy) {
    return Text(
      switch (strategy) {
        ConcurrencyExecutorStrategy.switchMap =>
          'Отменяет предыдущий запрос и запускает новый',
        ConcurrencyExecutorStrategy.exhaustMap =>
          'Игнорирует новые запросы пока выполняется текущий',
        ConcurrencyExecutorStrategy.mergeMap =>
          'Выполняет все запросы параллельно, не отменяя предыдущие',
        ConcurrencyExecutorStrategy.concatMap =>
          'Выполняет запросы по очереди, ждёт завершения предыдущего',
      },
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 8,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: GridView.builder(
          physics: NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
          ),
          itemCount: _executorMap.length,
          itemBuilder: (context, index) {
            final executorEntry = _executorMap.entries.elementAt(index);
            final executor = executorEntry.value;
            final strategy = executor.strategy;
            final logger = CustomLogger(owner: strategy.name);
            void execute() async {
              executor.execute(
                (handler) async {
                  await Future.delayed(Duration(seconds: 3));
                },
                onStart: (id) {
                  logger.log('start $id');
                },
                onCancelled: (result) {
                  logger.log('cancelled: ${result.id}');
                },
                onSuccess: (result) {
                  logger.log('success: ${result.id}');
                },
              );
            }

            return Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                border: Border.all(),
              ),
              child: Column(
                children: [
                  buildStrategyTitle(strategy),
                  buildStrategyDescription(strategy),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: buildButton(
                            title: 'Try out',
                            onPressed: () {
                              for (var i = 0; i < 3; i++) {
                                Future.delayed(
                                  Duration(seconds: i),
                                  execute,
                                );
                              }
                            },
                          ),
                        ),
                        Flexible(
                          child: buildButton(
                            title: 'Cancel all',
                            onPressed: () {
                              executor.cancelAll();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
