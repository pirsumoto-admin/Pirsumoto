import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirsumoto/features/form/form_provider.dart';

void main() {
  test('changing cars clears previous description, mileage and photos', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final form = container.read(formControllerProvider.notifier);
    form.updateField('license', '1234567');
    form.updateField('description', 'Old Peugeot description');
    form.updateField('km', '99000');
    form.addImage('/old/photo.jpg');
    form.updateFromAI({'license':'7654321', 'maker':'Hyundai', 'model':'i10'});
    final state = container.read(formControllerProvider);
    expect(state.license, '7654321');
    expect(state.description, isEmpty);
    expect(state.km, isEmpty);
    expect(state.images, isEmpty);
  });
}
