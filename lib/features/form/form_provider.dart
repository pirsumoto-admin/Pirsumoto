import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'form_provider.freezed.dart';
part 'form_provider.g.dart';

@freezed
abstract class FormState with _$FormState {
  const factory FormState({
    @Default(1) int currentStep,
    @Default(false) bool isTypingMode,
    @Default('') String license,
    @Default('') String color,
    @Default('') String maker,
    @Default('') String model,
    @Default('') String year,
    @Default('') String month,
    @Default('') String test,
    @Default('') String hand,
    @Default('') String ownership,
    @Default('') String prevOwnership,
    @Default('') String km,
    @Default('') String price,
    @Default('') String handicapped,
    @Default('טוב') String vehicleCondition,
    @Default('') String description,
    @Default('') String fuelType,
    @Default('') String gear,
    @Default([]) List<String> images,
    @Default('') String aiResponse,
    @Default(false) bool isRecording,
    @Default(false) bool isProcessing,
    @Default([]) List<String> warranties,
    @Default({}) Map<String, String> warrantyDurations,
    @Default([]) List<String> treatments,
    @Default([]) List<String> services,
  }) = _FormState;
}

@riverpod
class FormController extends _$FormController {
  @override
  FormState build() {
    return const FormState();
  }

  void updateField(String field, String value) {
    // In a full implementation, you'd map the field string to the state copyWith.
    // Simplifying with explicit methods or a switch map.
    switch (field) {
      case 'license':
        state = state.copyWith(license: value);
        break;
      case 'color':
        state = state.copyWith(color: value);
        break;
      case 'maker':
        state = state.copyWith(maker: value);
        break;
      case 'model':
        state = state.copyWith(model: value);
        break;
      case 'year':
        state = state.copyWith(year: value);
        break;
      case 'month':
        state = state.copyWith(month: value);
        break;
      case 'test':
        state = state.copyWith(test: value);
        break;
      case 'hand':
        state = state.copyWith(hand: value);
        break;
      case 'ownership':
        state = state.copyWith(ownership: value);
        break;
      case 'prevOwnership':
        state = state.copyWith(prevOwnership: value);
        break;
      case 'km':
        state = state.copyWith(km: value);
        break;
      case 'price':
        state = state.copyWith(price: value);
        break;
      case 'handicapped':
        state = state.copyWith(handicapped: value);
        break;
      case 'vehicleCondition':
        state = state.copyWith(vehicleCondition: value);
        break;
      case 'description':
        state = state.copyWith(description: value);
        break;
      case 'fuelType':
        state = state.copyWith(fuelType: value);
        break;
      case 'gear':
        state = state.copyWith(gear: value);
        break;
    }
  }

  void setStep(int step) {
    state = state.copyWith(currentStep: step);
  }

  void toggleTypingMode() {
    state = state.copyWith(isTypingMode: !state.isTypingMode);
  }

  void setRecording(bool isRecording) {
    state = state.copyWith(isRecording: isRecording);
  }

  void updateFromAI(Map<String, dynamic> data) {
    state = state.copyWith(
      license: data['license']?.toString() ?? state.license,
      color: data['color']?.toString() ?? state.color,
      month: data['month']?.toString() ?? state.month,
      test: data['test']?.toString() ?? state.test,
      hand: data['hand']?.toString() ?? state.hand,
      ownership: data['ownership']?.toString() ?? state.ownership,
      prevOwnership: data['prevOwnership']?.toString() ?? state.prevOwnership,
      km: data['km']?.toString() ?? state.km,
      price: data['price']?.toString() ?? state.price,
      handicapped: data['handicapped']?.toString() ?? state.handicapped,
      vehicleCondition:
          data['vehicleCondition']?.toString() ?? state.vehicleCondition,
      description: data['description']?.toString() ?? state.description,
      gear: data['gear']?.toString() ?? state.gear,
      isTypingMode: true,
      currentStep: 2,
    );
  }

  void addImage(String path) {
    state = state.copyWith(images: [...state.images, path]);
    if (state.currentStep < 3) state = state.copyWith(currentStep: 3);
  }

  void removeImage(int index) {
    if (index >= 0 && index < state.images.length) {
      final newImages = List<String>.from(state.images)..removeAt(index);
      state = state.copyWith(images: newImages);
    }
  }

  void setProcessing(bool isProcessing) {
    state = state.copyWith(isProcessing: isProcessing);
  }

  void loadFromListing(Map<String, dynamic> listing) {
    List<String> images = [];
    final rawImages = listing['images'];
    if (rawImages is List) {
      images =
          rawImages
              .map((img) {
                if (img is String) return img;
                if (img is Map) return (img['url'] ?? '').toString();
                return '';
              })
              .where((s) => s.isNotEmpty)
              .toList();
    }
    state = state.copyWith(
      license: listing['license']?.toString() ?? '',
      color: listing['color']?.toString() ?? '',
      maker: listing['maker']?.toString() ?? '',
      model: listing['model']?.toString() ?? '',
      year: listing['year']?.toString() ?? '',
      month: listing['month']?.toString() ?? '',
      test: listing['test']?.toString() ?? '',
      hand: listing['hand']?.toString() ?? '',
      ownership: listing['ownership']?.toString() ?? '',
      prevOwnership: listing['prevOwnership']?.toString() ?? '',
      km: listing['km']?.toString() ?? '',
      price: listing['price']?.toString() ?? '',
      handicapped: listing['handicapped']?.toString() ?? '',
      vehicleCondition: listing['vehicleCondition']?.toString() ?? 'טוב',
      description: listing['description']?.toString() ?? '',
      gear: listing['gear']?.toString() ?? '',
      images: images,
      warranties:
          listing['warranties'] != null
              ? List<String>.from(listing['warranties'])
              : [],
      warrantyDurations:
          listing['warrantyDurations'] != null
              ? Map<String, String>.from(listing['warrantyDurations'])
              : {},
      treatments:
          listing['treatments'] != null
              ? List<String>.from(listing['treatments'])
              : [],
      services:
          listing['services'] != null
              ? List<String>.from(listing['services'])
              : [],
      isTypingMode: true,
      currentStep: 2,
    );
  }

  void clearForm() {
    state = const FormState();
  }
}
