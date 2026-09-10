import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/agent_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AgentConfigService.instance.resetForTesting();
  });

  group('AgentConfigService Unit Tests', () {
    test('provides default system prompt and rules when uninitialized/empty', () {
      final service = AgentConfigService.instance;

      expect(service.systemPrompt, contains('אתה עוזר שיחה חכם ומומחה לחילוץ מידע'));
      expect(service.allowedColors, contains('לבן'));
      expect(service.allowedColors, contains('שחור'));
      expect(service.allowedConditions, contains('מצוין'));
      expect(service.allowedOwnerships, contains('פרטית'));
      expect(service.minHand, equals(1));
      expect(service.maxHand, equals(15));
    });

    test('replaces placeholders in color matching prompt correctly', () {
      final service = AgentConfigService.instance;
      final formattedPrompt = service.getColorMatchingPrompt('כסוף מטאלי', ['אפור', 'לבן']);

      expect(formattedPrompt, contains('"כסוף מטאלי"'));
      expect(formattedPrompt, contains('אפור, לבן'));
    });

    test('falls back gracefully to cached values when firestore cannot be contacted', () async {
      final service = AgentConfigService.instance;
      final updated = await service.checkAndUpdateConfigIfNeeded(force: true);

      // In test environment without Firebase app, it gracefully catches error and returns false
      expect(updated, isFalse);
      expect(service.systemPrompt, isNotEmpty);
    });

    test('includes updated KM rules (miles, clock, dots, commas)', () {
      final service = AgentConfigService.instance;
      expect(service.kmRule, contains('מיילים'));
      expect(service.kmRule, contains('שעון'));
      expect(service.systemPrompt, contains('מיילים, ק"מ או שעון'));
    });

    test('rules_md markdown is fetched, cached, and wrapped in <agent_rules>', () async {
      final service = AgentConfigService.instance;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'agent_config_rules_md',
        '# Custom Markdown Rules\n- always treat digits with a comma in them as a number\n- convert miles to km',
      );
      await service.checkAndUpdateConfigIfNeeded(force: true);

      expect(service.rulesMd, contains('# Custom Markdown Rules'));
      expect(service.systemPrompt, contains('<agent_rules>'));
      expect(service.systemPrompt, contains('# Custom Markdown Rules'));
      expect(service.systemPrompt, contains('always treat digits with a comma in them as a number'));
      expect(service.systemPrompt, contains('</agent_rules>'));
    });
  });
}
