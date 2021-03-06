// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:path/path.dart' as path;
import 'package:pub/src/io.dart';
import 'package:scheduled_test/scheduled_test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

// Regression test for issue 16470.

main() {
  integration('checks out the repository for a locked revision', () {
    ensureGit();

    d.git('foo.git', [d.libDir('foo'), d.libPubspec('foo', '1.0.0')]).create();

    d.appDir({
      "foo": {"git": "../foo.git"}
    }).create();

    // This get should lock the foo.git dependency to the current revision.
    // TODO(rnystrom): Remove "--packages-dir" and validate using the
    // ".packages" file instead of looking in the "packages" directory.
    pubGet(args: ["--packages-dir"]);

    d.dir(packagesPath, [
      d.dir('foo', [d.file('foo.dart', 'main() => "foo";')])
    ]).validate();

    // Delete the packages path and the cache to simulate a brand new checkout
    // of the application.
    schedule(() => deleteEntry(path.join(sandboxDir, packagesPath)));
    schedule(() => deleteEntry(path.join(sandboxDir, cachePath)));

    d.git('foo.git',
        [d.libDir('foo', 'foo 2'), d.libPubspec('foo', '1.0.0')]).commit();

    // This get shouldn't upgrade the foo.git dependency due to the lockfile.
    // TODO(rnystrom): Remove "--packages-dir" and validate using the
    // ".packages" file instead of looking in the "packages" directory.
    pubGet(args: ["--packages-dir"]);

    d.dir(packagesPath, [
      d.dir('foo', [d.file('foo.dart', 'main() => "foo";')])
    ]).validate();
  });
}
