// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'form_provider.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$FormState {

 int get currentStep; bool get isTypingMode; String get license; String get maker; String get model; String get year; String get month; String get test; String get hand; String get ownership; String get prevOwnership; String get km; String get price; String get handicapped; String get description; List<String> get images; String get aiResponse; bool get isRecording; bool get isProcessing;
/// Create a copy of FormState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FormStateCopyWith<FormState> get copyWith => _$FormStateCopyWithImpl<FormState>(this as FormState, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FormState&&(identical(other.currentStep, currentStep) || other.currentStep == currentStep)&&(identical(other.isTypingMode, isTypingMode) || other.isTypingMode == isTypingMode)&&(identical(other.license, license) || other.license == license)&&(identical(other.maker, maker) || other.maker == maker)&&(identical(other.model, model) || other.model == model)&&(identical(other.year, year) || other.year == year)&&(identical(other.month, month) || other.month == month)&&(identical(other.test, test) || other.test == test)&&(identical(other.hand, hand) || other.hand == hand)&&(identical(other.ownership, ownership) || other.ownership == ownership)&&(identical(other.prevOwnership, prevOwnership) || other.prevOwnership == prevOwnership)&&(identical(other.km, km) || other.km == km)&&(identical(other.price, price) || other.price == price)&&(identical(other.handicapped, handicapped) || other.handicapped == handicapped)&&(identical(other.description, description) || other.description == description)&&const DeepCollectionEquality().equals(other.images, images)&&(identical(other.aiResponse, aiResponse) || other.aiResponse == aiResponse)&&(identical(other.isRecording, isRecording) || other.isRecording == isRecording)&&(identical(other.isProcessing, isProcessing) || other.isProcessing == isProcessing));
}


@override
int get hashCode => Object.hashAll([runtimeType,currentStep,isTypingMode,license,maker,model,year,month,test,hand,ownership,prevOwnership,km,price,handicapped,description,const DeepCollectionEquality().hash(images),aiResponse,isRecording,isProcessing]);

@override
String toString() {
  return 'FormState(currentStep: $currentStep, isTypingMode: $isTypingMode, license: $license, maker: $maker, model: $model, year: $year, month: $month, test: $test, hand: $hand, ownership: $ownership, prevOwnership: $prevOwnership, km: $km, price: $price, handicapped: $handicapped, description: $description, images: $images, aiResponse: $aiResponse, isRecording: $isRecording, isProcessing: $isProcessing)';
}


}

/// @nodoc
abstract mixin class $FormStateCopyWith<$Res>  {
  factory $FormStateCopyWith(FormState value, $Res Function(FormState) _then) = _$FormStateCopyWithImpl;
@useResult
$Res call({
 int currentStep, bool isTypingMode, String license, String maker, String model, String year, String month, String test, String hand, String ownership, String prevOwnership, String km, String price, String handicapped, String description, List<String> images, String aiResponse, bool isRecording, bool isProcessing
});




}
/// @nodoc
class _$FormStateCopyWithImpl<$Res>
    implements $FormStateCopyWith<$Res> {
  _$FormStateCopyWithImpl(this._self, this._then);

  final FormState _self;
  final $Res Function(FormState) _then;

/// Create a copy of FormState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? currentStep = null,Object? isTypingMode = null,Object? license = null,Object? maker = null,Object? model = null,Object? year = null,Object? month = null,Object? test = null,Object? hand = null,Object? ownership = null,Object? prevOwnership = null,Object? km = null,Object? price = null,Object? handicapped = null,Object? description = null,Object? images = null,Object? aiResponse = null,Object? isRecording = null,Object? isProcessing = null,}) {
  return _then(_self.copyWith(
currentStep: null == currentStep ? _self.currentStep : currentStep // ignore: cast_nullable_to_non_nullable
as int,isTypingMode: null == isTypingMode ? _self.isTypingMode : isTypingMode // ignore: cast_nullable_to_non_nullable
as bool,license: null == license ? _self.license : license // ignore: cast_nullable_to_non_nullable
as String,maker: null == maker ? _self.maker : maker // ignore: cast_nullable_to_non_nullable
as String,model: null == model ? _self.model : model // ignore: cast_nullable_to_non_nullable
as String,year: null == year ? _self.year : year // ignore: cast_nullable_to_non_nullable
as String,month: null == month ? _self.month : month // ignore: cast_nullable_to_non_nullable
as String,test: null == test ? _self.test : test // ignore: cast_nullable_to_non_nullable
as String,hand: null == hand ? _self.hand : hand // ignore: cast_nullable_to_non_nullable
as String,ownership: null == ownership ? _self.ownership : ownership // ignore: cast_nullable_to_non_nullable
as String,prevOwnership: null == prevOwnership ? _self.prevOwnership : prevOwnership // ignore: cast_nullable_to_non_nullable
as String,km: null == km ? _self.km : km // ignore: cast_nullable_to_non_nullable
as String,price: null == price ? _self.price : price // ignore: cast_nullable_to_non_nullable
as String,handicapped: null == handicapped ? _self.handicapped : handicapped // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,images: null == images ? _self.images : images // ignore: cast_nullable_to_non_nullable
as List<String>,aiResponse: null == aiResponse ? _self.aiResponse : aiResponse // ignore: cast_nullable_to_non_nullable
as String,isRecording: null == isRecording ? _self.isRecording : isRecording // ignore: cast_nullable_to_non_nullable
as bool,isProcessing: null == isProcessing ? _self.isProcessing : isProcessing // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [FormState].
extension FormStatePatterns on FormState {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _FormState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _FormState() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _FormState value)  $default,){
final _that = this;
switch (_that) {
case _FormState():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _FormState value)?  $default,){
final _that = this;
switch (_that) {
case _FormState() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int currentStep,  bool isTypingMode,  String license,  String maker,  String model,  String year,  String month,  String test,  String hand,  String ownership,  String prevOwnership,  String km,  String price,  String handicapped,  String description,  List<String> images,  String aiResponse,  bool isRecording,  bool isProcessing)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _FormState() when $default != null:
return $default(_that.currentStep,_that.isTypingMode,_that.license,_that.maker,_that.model,_that.year,_that.month,_that.test,_that.hand,_that.ownership,_that.prevOwnership,_that.km,_that.price,_that.handicapped,_that.description,_that.images,_that.aiResponse,_that.isRecording,_that.isProcessing);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int currentStep,  bool isTypingMode,  String license,  String maker,  String model,  String year,  String month,  String test,  String hand,  String ownership,  String prevOwnership,  String km,  String price,  String handicapped,  String description,  List<String> images,  String aiResponse,  bool isRecording,  bool isProcessing)  $default,) {final _that = this;
switch (_that) {
case _FormState():
return $default(_that.currentStep,_that.isTypingMode,_that.license,_that.maker,_that.model,_that.year,_that.month,_that.test,_that.hand,_that.ownership,_that.prevOwnership,_that.km,_that.price,_that.handicapped,_that.description,_that.images,_that.aiResponse,_that.isRecording,_that.isProcessing);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int currentStep,  bool isTypingMode,  String license,  String maker,  String model,  String year,  String month,  String test,  String hand,  String ownership,  String prevOwnership,  String km,  String price,  String handicapped,  String description,  List<String> images,  String aiResponse,  bool isRecording,  bool isProcessing)?  $default,) {final _that = this;
switch (_that) {
case _FormState() when $default != null:
return $default(_that.currentStep,_that.isTypingMode,_that.license,_that.maker,_that.model,_that.year,_that.month,_that.test,_that.hand,_that.ownership,_that.prevOwnership,_that.km,_that.price,_that.handicapped,_that.description,_that.images,_that.aiResponse,_that.isRecording,_that.isProcessing);case _:
  return null;

}
}

}

/// @nodoc


class _FormState implements FormState {
  const _FormState({this.currentStep = 1, this.isTypingMode = false, this.license = '', this.maker = '', this.model = '', this.year = '', this.month = '', this.test = '', this.hand = '', this.ownership = '', this.prevOwnership = '', this.km = '', this.price = '', this.handicapped = '', this.description = '', final  List<String> images = const [], this.aiResponse = '', this.isRecording = false, this.isProcessing = false}): _images = images;
  

@override@JsonKey() final  int currentStep;
@override@JsonKey() final  bool isTypingMode;
@override@JsonKey() final  String license;
@override@JsonKey() final  String maker;
@override@JsonKey() final  String model;
@override@JsonKey() final  String year;
@override@JsonKey() final  String month;
@override@JsonKey() final  String test;
@override@JsonKey() final  String hand;
@override@JsonKey() final  String ownership;
@override@JsonKey() final  String prevOwnership;
@override@JsonKey() final  String km;
@override@JsonKey() final  String price;
@override@JsonKey() final  String handicapped;
@override@JsonKey() final  String description;
 final  List<String> _images;
@override@JsonKey() List<String> get images {
  if (_images is EqualUnmodifiableListView) return _images;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_images);
}

@override@JsonKey() final  String aiResponse;
@override@JsonKey() final  bool isRecording;
@override@JsonKey() final  bool isProcessing;

/// Create a copy of FormState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FormStateCopyWith<_FormState> get copyWith => __$FormStateCopyWithImpl<_FormState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FormState&&(identical(other.currentStep, currentStep) || other.currentStep == currentStep)&&(identical(other.isTypingMode, isTypingMode) || other.isTypingMode == isTypingMode)&&(identical(other.license, license) || other.license == license)&&(identical(other.maker, maker) || other.maker == maker)&&(identical(other.model, model) || other.model == model)&&(identical(other.year, year) || other.year == year)&&(identical(other.month, month) || other.month == month)&&(identical(other.test, test) || other.test == test)&&(identical(other.hand, hand) || other.hand == hand)&&(identical(other.ownership, ownership) || other.ownership == ownership)&&(identical(other.prevOwnership, prevOwnership) || other.prevOwnership == prevOwnership)&&(identical(other.km, km) || other.km == km)&&(identical(other.price, price) || other.price == price)&&(identical(other.handicapped, handicapped) || other.handicapped == handicapped)&&(identical(other.description, description) || other.description == description)&&const DeepCollectionEquality().equals(other._images, _images)&&(identical(other.aiResponse, aiResponse) || other.aiResponse == aiResponse)&&(identical(other.isRecording, isRecording) || other.isRecording == isRecording)&&(identical(other.isProcessing, isProcessing) || other.isProcessing == isProcessing));
}


@override
int get hashCode => Object.hashAll([runtimeType,currentStep,isTypingMode,license,maker,model,year,month,test,hand,ownership,prevOwnership,km,price,handicapped,description,const DeepCollectionEquality().hash(_images),aiResponse,isRecording,isProcessing]);

@override
String toString() {
  return 'FormState(currentStep: $currentStep, isTypingMode: $isTypingMode, license: $license, maker: $maker, model: $model, year: $year, month: $month, test: $test, hand: $hand, ownership: $ownership, prevOwnership: $prevOwnership, km: $km, price: $price, handicapped: $handicapped, description: $description, images: $images, aiResponse: $aiResponse, isRecording: $isRecording, isProcessing: $isProcessing)';
}


}

/// @nodoc
abstract mixin class _$FormStateCopyWith<$Res> implements $FormStateCopyWith<$Res> {
  factory _$FormStateCopyWith(_FormState value, $Res Function(_FormState) _then) = __$FormStateCopyWithImpl;
@override @useResult
$Res call({
 int currentStep, bool isTypingMode, String license, String maker, String model, String year, String month, String test, String hand, String ownership, String prevOwnership, String km, String price, String handicapped, String description, List<String> images, String aiResponse, bool isRecording, bool isProcessing
});




}
/// @nodoc
class __$FormStateCopyWithImpl<$Res>
    implements _$FormStateCopyWith<$Res> {
  __$FormStateCopyWithImpl(this._self, this._then);

  final _FormState _self;
  final $Res Function(_FormState) _then;

/// Create a copy of FormState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? currentStep = null,Object? isTypingMode = null,Object? license = null,Object? maker = null,Object? model = null,Object? year = null,Object? month = null,Object? test = null,Object? hand = null,Object? ownership = null,Object? prevOwnership = null,Object? km = null,Object? price = null,Object? handicapped = null,Object? description = null,Object? images = null,Object? aiResponse = null,Object? isRecording = null,Object? isProcessing = null,}) {
  return _then(_FormState(
currentStep: null == currentStep ? _self.currentStep : currentStep // ignore: cast_nullable_to_non_nullable
as int,isTypingMode: null == isTypingMode ? _self.isTypingMode : isTypingMode // ignore: cast_nullable_to_non_nullable
as bool,license: null == license ? _self.license : license // ignore: cast_nullable_to_non_nullable
as String,maker: null == maker ? _self.maker : maker // ignore: cast_nullable_to_non_nullable
as String,model: null == model ? _self.model : model // ignore: cast_nullable_to_non_nullable
as String,year: null == year ? _self.year : year // ignore: cast_nullable_to_non_nullable
as String,month: null == month ? _self.month : month // ignore: cast_nullable_to_non_nullable
as String,test: null == test ? _self.test : test // ignore: cast_nullable_to_non_nullable
as String,hand: null == hand ? _self.hand : hand // ignore: cast_nullable_to_non_nullable
as String,ownership: null == ownership ? _self.ownership : ownership // ignore: cast_nullable_to_non_nullable
as String,prevOwnership: null == prevOwnership ? _self.prevOwnership : prevOwnership // ignore: cast_nullable_to_non_nullable
as String,km: null == km ? _self.km : km // ignore: cast_nullable_to_non_nullable
as String,price: null == price ? _self.price : price // ignore: cast_nullable_to_non_nullable
as String,handicapped: null == handicapped ? _self.handicapped : handicapped // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,images: null == images ? _self._images : images // ignore: cast_nullable_to_non_nullable
as List<String>,aiResponse: null == aiResponse ? _self.aiResponse : aiResponse // ignore: cast_nullable_to_non_nullable
as String,isRecording: null == isRecording ? _self.isRecording : isRecording // ignore: cast_nullable_to_non_nullable
as bool,isProcessing: null == isProcessing ? _self.isProcessing : isProcessing // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
