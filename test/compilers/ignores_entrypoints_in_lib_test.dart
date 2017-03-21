// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS d.file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:scheduled_test/scheduled_test.dart';

import '../descriptor.dart' as d;
import '../test_pub.dart';
import '../serve/utils.dart';

main() {
  setUp(() {
    d.dir(appPath, [
      d.appPubspec(),
      d.dir('lib', [
        d.file('file.dart', 'void main() => print("hello");'),
      ]),
      d.dir('web', [
        d.file('index.html', 'html'),
      ])
    ]).create();
    pubGet();
  });

  runTests("dart2js");
  runTests("dartdevc");
}

void runTests(String compiler) {
  group(compiler, () {
    integration("build ignores Dart entrypoints in lib", () {
      schedulePub(
          args: ["build", "--all", "--compiler=$compiler"],
          output: new RegExp(r'Built \d file[s]? to "build".'));

      d.dir(appPath, [
        d.dir('build', [d.nothing('lib')])
      ]).validate();
    });

    integration("serve ignores Dart entrypoints in lib", () {
      pubServe(args: ["--compiler=$compiler"]);
      requestShould404("packages/myapp/main.dart.js");
      endPubServe();
    });
  });
}
