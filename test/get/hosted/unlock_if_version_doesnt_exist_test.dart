// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:path/path.dart' as p;
import 'package:pub/src/io.dart';
import 'package:scheduled_test/scheduled_test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

main() {
  integration('upgrades a locked pub server package with a nonexistent version',
      () {
    servePackages((builder) => builder.serve("foo", "1.0.0"));

    d.appDir({"foo": "any"}).create();
    pubGet();
    d.appPackagesFile({"foo": "1.0.0"}).validate();

    schedule(() => deleteEntry(p.join(sandboxDir, cachePath)));

    globalPackageServer.replace((builder) => builder.serve("foo", "1.0.1"));
    pubGet();
    d.appPackagesFile({"foo": "1.0.1"}).validate();
  });
}
