import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'preset_login_screen.dart';

Future<bool?> showPresetLoginDialog(
  BuildContext context, {
  bool isFromWebView = false,
  VoidCallback? onReload,
}) async {
  String trText(String key, {required String he, required String en}) {
    final isEn = context.locale.languageCode == 'en';
    final fallback = isEn ? en : he;
    final val = tr(key);
    if (val == key || val.isEmpty) return fallback;
    return val;
  }

  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 8,
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF3B5BDB).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.vpn_key_rounded,
                color: Color(0xFF3B5BDB),
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                trText(
                  'preset_login.dialog_title',
                  he: 'התחברות מראש לאתרים',
                  en: 'Preset Login to Websites',
                ),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                trText(
                  'preset_login.dialog_description',
                  he:
                      'בחר אתר כדי לוודא שאתה מחובר ושהעוגיות נשמרות עבור האוטומציה:',
                  en:
                      'Select a website to verify your login and ensure session cookies are saved for smooth automation:',
                ),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 16),
              // Yad2 Tile
              _buildPresetPlatformTile(
                title: trText(
                  'preset_login.yad2_title',
                  he: 'יד 2 (Yad2)',
                  en: 'Yad2',
                ),
                subtitle: trText(
                  'preset_login.yad2_subtitle',
                  he: 'אימות התחברות ושמירת עוגיות ל-Yad2',
                  en: 'Validate Yad2 login & saved cookies',
                ),
                icon: Icons.directions_car_filled_rounded,
                color: const Color(0xFFFF7A00),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (_) => const PresetLoginScreen(
                            platform: PresetPlatform.yad2,
                          ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              // Facebook Tile
              _buildPresetPlatformTile(
                title: trText(
                  'preset_login.facebook_title',
                  he: 'פייסבוק (Facebook)',
                  en: 'Facebook',
                ),
                subtitle: trText(
                  'preset_login.facebook_subtitle',
                  he: 'אימות התחברות ושמירת עוגיות לפייסבוק',
                  en: 'Validate Facebook login & saved cookies',
                ),
                icon: Icons.facebook_rounded,
                color: const Color(0xFF1877F2),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (_) => const PresetLoginScreen(
                            platform: PresetPlatform.facebook,
                          ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          if (!isFromWebView)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                trText('preset_login.close', he: 'סגור', en: 'Close'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          if (isFromWebView)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF7A00),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 11,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                elevation: 2,
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
                onReload?.call();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(
                trText(
                  'preset_login.close_and_reload',
                  he: 'סגור ורענן דף',
                  en: 'Close & Reload Page',
                ),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
        ],
      );
    },
  );
}

Widget _buildPresetPlatformTile({
  required String title,
  required String subtitle,
  required IconData icon,
  required Color color,
  required VoidCallback onTap,
}) {
  return Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.25), width: 1.5),
      boxShadow: [
        BoxShadow(
          color: color.withValues(alpha: 0.08),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.open_in_new_rounded, color: color, size: 20),
            ],
          ),
        ),
      ),
    ),
  );
}
