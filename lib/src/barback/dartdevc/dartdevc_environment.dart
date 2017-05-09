// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/analyzer.dart';
import 'package:barback/barback.dart';
import 'package:cli_util/cli_util.dart' as cli_util;
import 'package:path/path.dart' as p;

import 'dartdevc_bootstrap_transformer.dart';
import 'dartdevc_module_transformer.dart';
import 'linked_summary_transformer.dart';
import 'module_computer.dart';
import 'module_reader.dart';
import 'scratch_space.dart';
import 'unlinked_summary_transformer.dart';

import '../../dart.dart';
import '../../io.dart';
import '../../package_graph.dart';

class _AssetCache {
  /// Assets first by package and then path, this allows us to invalidate whole
  /// packages efficiently.
  final _assets = <String, Map<String, Future<Asset>>>{};

  final PackageGraph _packageGraph;

  _AssetCache(this._packageGraph);

  Future<Asset> operator [](AssetId id) {
    var packageCache = _assets[id.package];
    if (packageCache == null) return null;
    return packageCache[id.path];
  }

  void operator []=(AssetId id, Future<Asset> asset) {
    var packageCache =
        _assets.putIfAbsent(id.package, () => <String, Future<Asset>>{});
    packageCache[id.path] = asset;
  }

  void invalidatePackage(String packageNameToInvalidate) {
    _assets.remove(packageNameToInvalidate);
    // Also invalidate any package with a transitive dep on the invalidated
    // package.
    var packageToInvalidate = _packageGraph.packages[packageNameToInvalidate];
    for (var packageName in _packageGraph.packages.keys) {
      if (_packageGraph
          .transitiveDependencies(packageName)
          .contains(packageToInvalidate)) {
        _assets.remove(packageName);
      }
    }
  }
}

class DartDevcEnvironment {
  final _AssetCache _assetCache;
  final Barback _barback;
  final Map<String, String> _environmentConstants;
  final BarbackMode _mode;
  ModuleReader _moduleReader;

  DartDevcEnvironment(this._barback, this._mode, this._environmentConstants,
      PackageGraph packageGraph)
      : _assetCache = new _AssetCache(packageGraph) {
    _moduleReader = new ModuleReader(_readModule);
  }

  Future<Asset> getAssetById(AssetId id) {
    if (_assetCache[id] == null) {
      _assetCache[id] = _buildAsset(id);
    }
    return _assetCache[id];
  }

  void invalidatePackage(String package) {
    _assetCache.invalidatePackage(package);
  }

  Future<Asset> _buildAsset(AssetId id) async {
    Asset asset;
    if (id.path.endsWith(unlinkedSummaryExtension)) {
      asset = await _buildUnlinkedSummary(id);
    } else if (id.path.endsWith(linkedSummaryExtension)) {
      asset = await _buildLinkedSummary(id);
    } else if (id.path.endsWith('.bootstrap.js') ||
        id.path.endsWith('.dart.js')) {
      asset = await _buildBootstrapJs(id);
    } else if (id.path.endsWith('require.js') ||
        id.path.endsWith('dart_sdk.js')) {
      asset = await _buildJsResource(id);
    } else if (id.path.endsWith('require.js.map') ||
        id.path.endsWith('dart_sdk.js.map')) {
      throw new AssetNotFoundException(id);
    } else if (id.path.endsWith('.js') || id.path.endsWith('.js.map')) {
      asset = await _buildJsModule(id);
    } else if (id.path.endsWith(moduleConfigName)) {
      asset = await _buildModuleConfig(id);
    }
    if (asset == null) throw new AssetNotFoundException(id);
    return asset;
  }

  Future<Asset> _buildModuleConfig(AssetId id) async {
    print('Building module config $id');
    var moduleDir = topLevelDir(id.path);
    var allAssets = await _barback.getAllAssets();
    var moduleAssets = allAssets.where((asset) =>
        asset.id.package == id.package &&
        asset.id.extension == '.dart' &&
        topLevelDir(asset.id.path) == moduleDir);
    var moduleMode =
        moduleDir == 'lib' ? ModuleMode.public : ModuleMode.private;
    var modules = await computeModules(moduleMode, moduleAssets);
    var encoded = JSON.encode(modules);
    print('Done building module config $id');
    return new Asset.fromString(id, encoded);
  }

  Future<Asset> _buildUnlinkedSummary(AssetId id) async {
    print('Building unlinked summary $id');
    var module = await _moduleReader.moduleFor(id);
    print('Read modules for unlinked summary $id');
    var scratchSpace = await ScratchSpace.create(module.assetIds, _readAsBytes);
    print('Created scratchspace for unlinked summary $id');
    var asset =
        await createUnlinkedSummaryForModule(module, scratchSpace, print);
    print('Done building unlinked summary $id');
    return asset;
  }

  Future<Asset> _buildLinkedSummary(AssetId id) async {
    print('Building linked summary $id');
    var module = await _moduleReader.moduleFor(id);
    var transitiveModuleDeps = await _moduleReader.readTransitiveDeps(module);
    var unlinkedSummaryIds =
        transitiveModuleDeps.map((depId) => depId.unlinkedSummaryId).toSet();
    var allAssetIds = new Set<AssetId>()
      ..addAll(module.assetIds)
      ..addAll(unlinkedSummaryIds);
    var scratchSpace = await ScratchSpace.create(allAssetIds, _readAsBytes);
    var asset = await createLinkedSummaryForModule(
        module, unlinkedSummaryIds, scratchSpace, print);
    print('Done building linked summary $id');
    return asset;
  }

  Future<Asset> _buildBootstrapJs(AssetId id) async {
    var dartId = id.changeExtension('');
    if (dartId.extension == '.bootstrap') dartId.changeExtension('.dart');
    var dartAsset = await _barback.getAssetById(dartId);
    var parsed = parseCompilationUnit(await dartAsset.readAsString());
    if (!isEntrypoint(parsed)) return null;
    var assets = await bootstrapEntrypoint(dartId, _mode, _moduleReader);
    _ensureCachedAssets(assets);
    return assets.firstWhere((asset) => asset.id == id, orElse: () => null);
  }

  Future<Asset> _buildJsModule(AssetId id) async {
    print('Building js module $id');
    var module = await _moduleReader.moduleFor(id);
    var transitiveModuleDeps = await _moduleReader.readTransitiveDeps(module);
    var linkedSummaryIds =
        transitiveModuleDeps.map((depId) => depId.linkedSummaryId).toSet();
    var allAssetIds = new Set<AssetId>()
      ..addAll(module.assetIds)
      ..addAll(linkedSummaryIds);
    var scratchSpace = await ScratchSpace.create(allAssetIds, _readAsBytes);
    var assets = await createDartdevcModule(module, scratchSpace,
        linkedSummaryIds, _environmentConstants, _mode, print);
    _ensureCachedAssets(assets);
    print('Done building js module $id: $assets');
    return assets.firstWhere((asset) => asset.id == id, orElse: () => null);
  }

  Future<Asset> _buildJsResource(AssetId id) async {
    var sdk = cli_util.getSdkDir();

    switch (p.url.basename(id.path)) {
      case 'dart_sdk.js':
        var sdkAmdJsPath =
            p.url.join(sdk.path, 'lib/dev_compiler/amd/dart_sdk.js');
        return new Asset.fromFile(id, new File(sdkAmdJsPath));
      case 'require.js':
        var requireJsPath =
            p.url.join(sdk.path, 'lib/dev_compiler/amd/require.js');
        return new Asset.fromFile(id, new File(requireJsPath));
      default:
        return null;
    }
  }

  void _ensureCachedAssets(Iterable<Asset> assets) {
    for (var asset in assets) {
      if (_assetCache[asset.id] == null) {
        _assetCache[asset.id] = new Future.value(asset);
      }
    }
  }

  Future<String> _readModule(AssetId moduleConfigId) async {
    var asset = await getAssetById(moduleConfigId);
    return asset.readAsString();
  }

  Stream<List<int>> _readAsBytes(AssetId id) {
    var controller = new StreamController<List<int>>();
    () async {
      Asset asset;
      try {
        asset = await _barback.getAssetById(id);
      } on AssetNotFoundException catch (_) {
        asset = await getAssetById(id);
      }
      await controller.addStream(asset.read());
      controller.close();
    }();
    return controller.stream;
  }
}
