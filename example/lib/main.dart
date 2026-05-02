import 'package:example/polling_example.dart';
import 'package:flutter/material.dart';

import 'example_page.dart';

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
            body: SizedBox.expand(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) {
                            return ExamplePage();
                          },
                        ),
                      );
                    },
                    child: Text('Open Concurrency example'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) {
                            return PollingExample();
                          },
                        ),
                      );
                    },
                    child: Text('Open PollingExecutor example'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
