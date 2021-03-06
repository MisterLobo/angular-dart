@Tags(const ['codegen'])
@TestOn('browser')
library angular2.test.core.linker.deferred_component_test;

import 'package:angular_test/angular_test.dart';
import 'package:test/test.dart';
import 'package:angular/angular.dart';

import 'deferred_view_with_ngmodel.dart';
import 'deferred_view_with_ngmodel.template.dart' deferred as deflib0;

import 'deferred_component_ngmodel_test.template.dart' as ng_generated;

void main() {
  ng_generated.initReflector();

  tearDown(disposeAnyRunningTest);

  test('should load a @deferred component', () async {
    final fixture = await new NgTestBed<TestContainerComponent>().create();
    await deflib0.loadLibrary();
    final view = fixture.rootElement.querySelector('my-deferred-input');
    expect(view.attributes['data-xyz'], 'testValue');
    await fixture.update((TestContainerComponent component) {
      component.testValue = 'testValue2';
    });
    expect(view, isNotNull);
    // If the update fails for testValue2, detectChangesInNestedViews is broken
    // for deferred ViewContainer, see generated code.
    expect(view.attributes['data-xyz'], 'testValue2');
  });
}

@Component(
  selector: 'test-container',
  directives: const [DeferredInputComponent],
  template: r'<my-deferred-input [attr.data-xyz]="testValue" @deferred>'
      '</my-deferred-input>',
)
class TestContainerComponent {
  String testValue = 'testValue';
}
