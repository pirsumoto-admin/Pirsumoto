import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/p2p_auto_publish_launcher.dart';

void main() {
  group('P2PAutoPublishLauncher target platform resolution', () {
    test('default / both enables both Yad2 and Facebook', () {
      final dataDefault = <String, String>{
        'maker': 'Toyota',
        'model': 'Corolla',
        'year': '2020',
        'price': '85000',
        'km': '50000',
        'hand': '1',
      };
      final publishDataDefault = P2PAutoPublishLauncher.buildPublishData(dataDefault);
      expect(publishDataDefault.includeYad2, isTrue);
      expect(publishDataDefault.includeFacebook, isTrue);

      final dataBoth = <String, String>{
        ...dataDefault,
        'publish_target': 'both',
      };
      final publishDataBoth = P2PAutoPublishLauncher.buildPublishData(dataBoth);
      expect(publishDataBoth.includeYad2, isTrue);
      expect(publishDataBoth.includeFacebook, isTrue);
    });

    test('yad2 only enables Yad2 and disables Facebook', () {
      final dataYad2 = <String, String>{
        'maker': 'Toyota',
        'model': 'Corolla',
        'year': '2020',
        'price': '85000',
        'km': '50000',
        'hand': '1',
        'publish_target': 'yad2',
      };
      final publishData = P2PAutoPublishLauncher.buildPublishData(dataYad2);
      expect(publishData.includeYad2, isTrue);
      expect(publishData.includeFacebook, isFalse);
    });

    test('facebook only disables Yad2 and enables Facebook', () {
      final dataFacebook = <String, String>{
        'maker': 'Toyota',
        'model': 'Corolla',
        'year': '2020',
        'price': '85000',
        'km': '50000',
        'hand': '1',
        'publish_target': 'facebook',
      };
      final publishData = P2PAutoPublishLauncher.buildPublishData(dataFacebook);
      expect(publishData.includeYad2, isFalse);
      expect(publishData.includeFacebook, isTrue);
    });

    test('explicit includeYad2 and includeFacebook strings are respected', () {
      final dataCustom = <String, String>{
        'maker': 'Toyota',
        'includeYad2': 'false',
        'includeFacebook': 'true',
      };
      final publishData = P2PAutoPublishLauncher.buildPublishData(dataCustom);
      expect(publishData.includeYad2, isFalse);
      expect(publishData.includeFacebook, isTrue);
    });
  });
}
