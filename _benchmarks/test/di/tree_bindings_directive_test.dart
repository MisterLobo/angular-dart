import 'package:_benchmarks/di/create_tree_bindings_directive.dart';
import 'package:angular_test/angular_test.dart';
import 'package:test/test.dart';

void main() {
  tearDown(disposeAnyRunningTest);

  test(
      'should create 20 DI bindings (reflective)',
      () => new NgTestBed<CreateTreeBindingsBenchmark>()
          .create()
          .then((fix) => fix.update((comp) => comp.ready = true)));
}
