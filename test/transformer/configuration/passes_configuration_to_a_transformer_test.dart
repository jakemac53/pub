// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS d.file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';
import '../../serve/utils.dart';

final transformer = """
import 'dart:async';
import 'dart:convert';

import 'package:barback/barback.dart';

class ConfigTransformer extends Transformer {
  final BarbackSettings settings;

  ConfigTransformer.asPlugin(this.settings);

  String get allowedExtensions => '.txt';

  Future apply(Transform transform) {
    return transform.primaryInput.readAsString().then((contents) {
      var id = transform.primaryInput.id.changeExtension(".json");
      transform.addOutput(
        new Asset.fromString(id, JSON.encode(settings.configuration)));
    });
  }
}
""";

main() {
  integration("passes configuration to a transformer", () {
    serveBarback();

    var configuration = {
      "param": ["list", "of", "values"]
    };

    d.dir(appPath, [
      d.pubspec({
        "name": "myapp",
        "transformers": [
          {"myapp/src/transformer": configuration}
        ],
        "dependencies": {"barback": "any"}
      }),
      d.dir("lib", [
        d.dir("src", [d.file("transformer.dart", transformer)])
      ]),
      d.dir("web", [d.file("foo.txt", "foo")])
    ]).create();

    pubGet();
    pubServe();
    requestShouldSucceed("foo.json", JSON.encode(configuration));
    endPubServe();
  });
}
