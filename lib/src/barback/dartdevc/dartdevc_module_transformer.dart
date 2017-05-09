// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:barback/barback.dart';
import 'package:bazel_worker/bazel_worker.dart';
import 'package:path/path.dart' as p;

import 'workers.dart';
import 'module.dart';
import 'module_reader.dart';
import 'scratch_space.dart';
import 'linked_summary_transformer.dart';

/// Creates dartdevc modules given [moduleConfigName] files which describe a set
/// of [Module]s.
///
/// Linked summaries should have already been created for all modules and will
/// be read in to create the modules.
class DartDevcModuleTransformer extends Transformer {
  @override
  String get allowedExtensions => moduleConfigName;

  final Map<String, String> environmentConstants;
  final BarbackMode mode;

  DartDevcModuleTransformer(this.mode, {this.environmentConstants = const {}});

  @override
  Future apply(Transform transform) async {
    ScratchSpace scratchSpace;
    var reader = new ModuleReader(transform.readInputAsString);
    var modules = await reader.readModules(transform.primaryInput.id);
    try {
      var allAssetIds = new Set<AssetId>();
      var summariesForModule = <ModuleId, Set<AssetId>>{};
      for (var module in modules) {
        var transitiveModuleDeps = await reader.readTransitiveDeps(module);
        var linkedSummaryIds =
            transitiveModuleDeps.map((depId) => depId.linkedSummaryId).toSet();
        summariesForModule[module.id] = linkedSummaryIds;
        allAssetIds..addAll(module.assetIds)..addAll(linkedSummaryIds);
      }
      // Create a single temp environment for all the modules in this package.
      scratchSpace =
          await ScratchSpace.create(allAssetIds, transform.readInput);

      // We only log warnings in debug mode for ddc modules because they don't
      // all need to compile successfully, only the ones imported by an
      // entrypoint do.
      var logError = mode == BarbackMode.RELEASE
          ? transform.logger.error
          : transform.logger.warning;
      await Future.wait(modules.map((m) async {
        var assets = await createDartdevcModule(m, scratchSpace,
            summariesForModule[m.id], environmentConstants, mode, logError);
        assets.forEach(transform.addOutput);
      }));
    } finally {
      scratchSpace?.delete();
    }
  }
}

/// Compiles [module] using the `dartdevc` binary from the SDK to a relative
/// path under the package that looks like `$outputDir/${module.id.name}.js`.
Future<List<Asset>> createDartdevcModule(
    Module module,
    ScratchSpace scratchSpace,
    Set<AssetId> linkedSummaryIds,
    Map<String, String> environmentConstants,
    BarbackMode mode,
    void logError(String message)) async {
  var jsOutputFile = scratchSpace.fileFor(module.id.jsId);
  var sdk_summary = p.url.join(sdkDir.path, 'lib/_internal/ddc_sdk.sum');
  var request = new WorkRequest();
  request.arguments.addAll([
    '--dart-sdk-summary=$sdk_summary',
    // TODO(jakemac53): Remove when no longer needed,
    // https://github.com/dart-lang/pub/issues/1583.
    '--unsafe-angular2-whitelist',
    '--modules=amd',
    '--dart-sdk=${sdkDir.path}',
    '--module-root=${scratchSpace.tempDir.path}',
    '--library-root=${p.dirname(jsOutputFile.path)}',
    '--summary-extension=${linkedSummaryExtension.substring(1)}',
    '--no-summarize',
    '-o',
    jsOutputFile.path,
  ]);

  if (mode == BarbackMode.RELEASE) {
    request.arguments.add('--no-source-map');
  }

  // Add environment constants.
  environmentConstants.forEach((key, value) {
    request.arguments.add('-D$key=$value');
  });

  // Add all the linked summaries as summary inputs.
  for (var id in linkedSummaryIds) {
    request.arguments.addAll(['-s', scratchSpace.fileFor(id).path]);
  }

  // Add URL mappings for all the package: files to tell DartDevc where to find
  // them.
  for (var id in module.assetIds) {
    var uri = canonicalUriFor(id);
    if (uri.startsWith('package:')) {
      request.arguments
          .add('--url-mapping=$uri,${scratchSpace.fileFor(id).path}');
    }
  }
  // And finally add all the urls to compile, using the package: path for files
  // under lib and the full absolute path for other files.
  request.arguments.addAll(module.assetIds.map((id) {
    var uri = canonicalUriFor(id);
    if (uri.startsWith('package:')) {
      return uri;
    }
    return scratchSpace.fileFor(id).path;
  }));

  var response = await dartdevcDriver.doWork(request);

  // TODO(jakemac53): Fix the ddc worker mode so it always sends back a bad
  // status code if something failed. Today we just make sure there is an output
  // js file to verify it was successful.
  if (response.exitCode != EXIT_CODE_OK || !jsOutputFile.existsSync()) {
    logError('Error compiling dartdevc module: ${module.id}.\n'
        '${response.output}');
    return [];
  } else {
    var outputs = <Asset>[];
    outputs.add(
        new Asset.fromBytes(module.id.jsId, jsOutputFile.readAsBytesSync()));
    if (mode == BarbackMode.DEBUG) {
      var sourceMapOutputId = module.id.jsId.addExtension('.map');
      var sourceMapFile = scratchSpace.fileFor(sourceMapOutputId);
      outputs.add(new Asset.fromBytes(
          sourceMapOutputId, sourceMapFile.readAsBytesSync()));
    }
    return outputs;
  }
}
