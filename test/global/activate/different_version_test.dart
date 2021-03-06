// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../../test_pub.dart';

main() {
  integration(
      "discards the previous active version if it doesn't match the "
      "constraint", () {
    servePackages((builder) {
      builder.serve("foo", "1.0.0");
      builder.serve("foo", "2.0.0");
    });

    // Activate 1.0.0.
    schedulePub(args: ["global", "activate", "foo", "1.0.0"]);

    // Activating it again with a different constraint changes the version.
    schedulePub(
        args: ["global", "activate", "foo", ">1.0.0"],
        output: """
        Package foo is currently active at version 1.0.0.
        Resolving dependencies...
        + foo 2.0.0
        Downloading foo 2.0.0...
        Precompiling executables...
        Activated foo 2.0.0.""");
  });
}
