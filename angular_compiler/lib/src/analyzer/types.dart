import 'package:source_gen/source_gen.dart';

// Where to find types provided by AngularDart.
const _angular = 'package:angular';
const _meta = '$_angular/src/core/metadata.dart';
const _di = '$_angular/src/core/di/decorators.dart';
const _injector = '$_angular/src/di/injector/injector.dart';
const _module = '$_angular/src/di/module.dart';
const _provider = '$_angular/src/di/provider.dart';
const _providerOf = '$_provider#Provider';
const _token = '$_angular/src/core/di/opaque_token.dart';

// Class metadata.
const $Directive = const TypeChecker.fromUrl('$_meta#Directive');
const $Component = const TypeChecker.fromUrl('$_meta#Component');
const $Pipe = const TypeChecker.fromUrl('$_meta#Pipe');
const $Injectable = const TypeChecker.fromUrl('$_di#Injectable');

// Parameter metadata.
const $Attribute = const TypeChecker.fromUrl('$_meta#Attribute');
const $Inject = const TypeChecker.fromUrl('$_di#Inject');
const $Optional = const TypeChecker.fromUrl('$_di#Optional');
const $Self = const TypeChecker.fromUrl('$_di#Self');
const $SkipSelf = const TypeChecker.fromUrl('$_di#SkipSelf');
const $Host = const TypeChecker.fromUrl('$_di#Host');

// Field metadata.
const $ContentChildren = const TypeChecker.fromUrl('$_meta#ContentChildren');
const $ContentChild = const TypeChecker.fromUrl('$_meta#ContentChild');
const $ViewChildren = const TypeChecker.fromUrl('$_meta#ViewChildren');
const $ViewChild = const TypeChecker.fromUrl('$_meta#ViewChild');
const $Input = const TypeChecker.fromUrl('$_meta#Input');
const $Output = const TypeChecker.fromUrl('$_meta#Output');
const $HostBinding = const TypeChecker.fromUrl('$_meta#HostBinding');
const $HostListener = const TypeChecker.fromUrl('$_meta#HostListener');

// Class types.
const $_GenerateInjector =
    const TypeChecker.fromUrl('$_injector#_GenerateInjector');
const $Module = const TypeChecker.fromUrl('$_module#Module');
const $Provider = const TypeChecker.fromUrl('$_provider#Provider');
const $StaticProvider = const TypeChecker.fromUrl('$_provider#StaticProvider');
const $ProviderUseClass = const TypeChecker.fromUrl('${_providerOf}UseClass');
const $ProviderUseMulti = const TypeChecker.fromUrl('${_providerOf}UseMulti');
const $OpaqueToken = const TypeChecker.fromUrl('$_token#OpaqueToken');
