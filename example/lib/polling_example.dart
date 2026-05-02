import 'dart:math';

import 'package:concurrency_executor/concurrency_executor.dart';
import 'package:flutter/material.dart';

class PollingExample extends StatefulWidget {
  const PollingExample({super.key});

  @override
  State<PollingExample> createState() => _PollingExampleState();
}

class _PollingExampleState extends State<PollingExample> {
  late final PollingExecutor<int> _executor = PollingExecutor(
    debug: true,
  );

  @override
  void dispose() {
    _executor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                _executor.execute(
                  willContinue: (result, attempts) => attempts < 3,
                  (item) async {
                    await Future.delayed(Duration(milliseconds: 400));
                    return Random().nextInt(100);
                  },
                );
              },
              child: Text('Run'),
            ),
            ElevatedButton(
              onPressed: () {
                _executor.cancel();
              },
              child: Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                _executor.dispose();
              },
              child: Text('Dispose'),
            ),
          ],
        ),
      ),
    );
  }
}
