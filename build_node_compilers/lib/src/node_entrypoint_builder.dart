// Copyright (c) 2018, Anatoly Pulyaevskiy. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:build_modules/build_modules.dart';

import 'common.dart';
import 'dart2js_bootstrap.dart';
import 'dev_compiler_bootstrap.dart';

const ddcBootstrapExtension = '.dart.bootstrap.js';
const jsEntrypointExtension = '.dart.js';
const jsEntrypointSourceMapExtension = '.dart.js.map';
const digestsEntrypointExtension = '.digests';
const mergedMetadataExtension = '.dart.ddc_merged_metadata';

/// Which compiler to use when compiling web entrypoints.
enum WebCompiler { Dart2Js, DartDevc }

/// The top level keys supported for the `options` config for the
/// [NodeEntrypointBuilder].
const _supportedOptions = [_compiler, _dart2jsArgs, _buildRootAppSummary];
const _buildRootAppSummary = 'build_root_app_summary';
const _compiler = 'compiler';
const _dart2jsArgs = 'dart2js_args';

/// The deprecated keys for the `options` config for the [NodeEntrypointBuilder].
const _deprecatedOptions = ['enable_sync_async', 'ignore_cast_failures'];

/// A builder which compiles entrypoints for the web.
///
/// Supports `dart2js` and `dartdevc`.
class NodeEntrypointBuilder implements Builder {
  final WebCompiler webCompiler;
  final List<String> dart2JsArgs;

  // TODO: Remove --no-sound-null-safety after migrating to nnbd.
  const NodeEntrypointBuilder(this.webCompiler, {this.dart2JsArgs = const []});

  factory NodeEntrypointBuilder.fromOptions(BuilderOptions options) {
    validateOptions(
      options.config,
      _supportedOptions,
      'build_node_compilers|entrypoint',
      deprecatedOptions: _deprecatedOptions,
    );
    var compilerOption = options.config[_compiler] as String? ?? 'dartdevc';
    WebCompiler compiler;
    switch (compilerOption) {
      case 'dartdevc':
        compiler = WebCompiler.DartDevc;
        break;
      case 'dart2js':
        compiler = WebCompiler.Dart2Js;
        break;
      default:
        throw ArgumentError.value(
          compilerOption,
          _compiler,
          'Only `dartdevc` and `dart2js` are supported.',
        );
    }

    if (options.config[_dart2jsArgs] is! List) {
      throw ArgumentError.value(
        options.config[_dart2jsArgs],
        _dart2jsArgs,
        'Expected a list for $_dart2jsArgs.',
      );
    }
    var dart2JsArgs =
        (options.config[_dart2jsArgs] as List?)
            ?.map((arg) => '$arg')
            .toList() ??
        const <String>[];

    return NodeEntrypointBuilder(compiler, dart2JsArgs: dart2JsArgs);
  }

  @override
  final buildExtensions = const {
    '.dart': [
      ddcBootstrapExtension,
      jsEntrypointExtension,
      jsEntrypointSourceMapExtension,
      digestsEntrypointExtension,
    ],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    var dartEntrypointId = buildStep.inputId;
    var isAppEntrypoint = await _isAppEntryPoint(dartEntrypointId, buildStep);
    if (!isAppEntrypoint) return;

    if (webCompiler == WebCompiler.DartDevc) {
      try {
        await bootstrapDdc(buildStep);
      } on MissingModulesException catch (e) {
        log.severe('$e');
      }
    } else if (webCompiler == WebCompiler.Dart2Js) {
      await bootstrapDart2Js(buildStep, dart2JsArgs);
    }
  }
}

/// Returns whether or not [dartId] is an app entrypoint (basically, whether
/// or not it has a `main` function).
Future<bool> _isAppEntryPoint(AssetId dartId, AssetReader reader) async {
  assert(dartId.extension == '.dart');
  // Skip reporting errors here, dartdevc will report them later with nicer
  // formatting.
  var parsed = parseString(
    content: await reader.readAsString(dartId),
    throwIfDiagnostics: false,
  ).unit;

  // Allow two or fewer arguments so that entrypoints intended for use with
  // [spawnUri] get counted.
  //
  // TODO: This misses the case where a Dart file doesn't contain main(),
  // but has a part that does, or it exports a `main` from another library.
  return parsed.declarations.any((node) {
    return node is FunctionDeclaration &&
        node.name.lexeme == 'main' &&
        node.functionExpression.parameters != null &&
        node.functionExpression.parameters!.parameters.length <= 2;
  });
}
