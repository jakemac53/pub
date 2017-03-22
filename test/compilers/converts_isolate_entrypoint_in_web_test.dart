// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS d.file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Dart2js can take a long time to compile dart code, so we increase the timeout
// to cope with that.
@Timeout.factor(3)
import 'package:scheduled_test/scheduled_test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';
import '../serve/utils.dart';

main() {
  setUp(() {
    d.dir(appPath, [
      d.appPubspec(),
      d.dir("web", [
        d.file(
            "isolate.dart",
            """
import 'dart:isolate';

void main(List<String> args, SendPort sendPort) => print('hello');""")
      ])
    ]).create();

    pubGet();
  });

  tearDown(() {
    endPubServe();
  });

  integration("dart2js converts a Dart isolate entrypoint in web to JS", () {
    pubServe();
    requestShouldSucceed("isolate.dart.js", contains("hello"));
  });

  integration("dartdevc converts a Dart isolate entrypoint in web to JS", () {
    pubServe(args: ["--compiler=dartdevc"]);
    requestShouldSucceed("isolate.dart.js", isNotEmpty);
    requestShouldSucceed("isolate.dart.module.js", contains("hello"));
  });
}
