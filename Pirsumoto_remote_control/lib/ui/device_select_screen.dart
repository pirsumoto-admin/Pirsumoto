import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import '../signaling/controller_signaling.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'app_theme.dart';
import 'remote_control_screen.dart';
import 'whatsapp_chat_screen.dart';

class DeviceSelectScreen extends StatefulWidget {
  const DeviceSelectScreen({super.key});

  @override
  State<DeviceSelectScreen> createState() => _DeviceSelectScreenState();
}

class _DeviceSelectScreenState extends State<DeviceSelectScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _customDeviceIdController = TextEditingController();
  final TextEditingController _controllerNameController = TextEditingController();

  String? _connectingDeviceId;
  String? _connectingType;
  String? _error;
  bool _showManualInput = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _controllerNameController.text = user?.displayName ??
        user?.email?.split('@').first ??
        'Controller';
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _customDeviceIdController.dispose();
    _controllerNameController.dispose();
    super.dispose();
  }

  void _openChatScreen({
    required String deviceId,
    String? modelName,
  }) {
    if (deviceId.isEmpty) {
      setState(() => _error = 'נא להזין מזהה מכשיר');
      return;
    }

    final displayName = (modelName != null && modelName.isNotEmpty)
        ? modelName
        : 'מכשיר ($deviceId)';

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WhatsAppChatScreen(
          deviceId: deviceId,
          deviceName: displayName,
        ),
      ),
    );
  }

  Future<void> _connectToDevice({
    required String deviceId,
    String? modelName,
    String sessionType = 'remote_control',
  }) async {
    if (deviceId.isEmpty) {
      setState(() => _error = 'נא להזין מזהה מכשיר');
      return;
    }

    if (sessionType == 'chat') {
      _openChatScreen(deviceId: deviceId, modelName: modelName);
      return;
    }

    setState(() {
      _connectingDeviceId = deviceId;
      _connectingType = sessionType;
      _error = null;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      final controllerId = _controllerNameController.text.trim().isNotEmpty
          ? _controllerNameController.text.trim()
          : (user?.displayName ?? 'Controller_${DateTime.now().millisecondsSinceEpoch % 1000}');

      final signaling = ControllerSignalingClient(
        deviceId: deviceId,
        controllerId: controllerId,
      );

      final session = ControllerWebRtcSession(
        signaling: signaling,
        sessionType: sessionType,
      );

      await session.initRenderer();
      session.connect();

      if (!mounted) return;

      setState(() {
        _connectingDeviceId = null;
        _connectingType = null;
      });

      final displayName = (modelName != null && modelName.isNotEmpty)
          ? modelName
          : 'מכשיר ($deviceId)';

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RemoteControlScreen(
            session: session,
            deviceName: displayName,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectingDeviceId = null;
          _connectingType = null;
          _error = 'שגיאה בהתחברות: $e';
        });
      }
    }
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        title: Text(
          'התנתקות',
          style: GoogleFonts.heebo(
            fontWeight: FontWeight.bold,
            color: AppColors.onSurface,
          ),
        ),
        content: Text(
          'האם ברצונך להתנתק מהחשבון?',
          style: GoogleFonts.heebo(color: AppColors.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'ביטול',
              style: GoogleFonts.heebo(color: AppColors.secondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryAction,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              'התנתקות',
              style: GoogleFonts.heebo(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await FirebaseAuth.instance.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final currentUid = currentUser?.uid;

    return Scaffold(
      backgroundColor: AppColors.neutral,
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar: "התנתקות" at physical top right, Brand at physical left
            Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: const BoxDecoration(
                color: AppColors.neutral,
                border: Border(
                  bottom: BorderSide(color: AppColors.border, width: 1),
                ),
              ),
              child: Row(
                children: [
                  // Physical top right (start of row in RTL): Logout
                  InkWell(
                    onTap: _signOut,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Transform.flip(
                            flipX: true,
                            child: const Icon(
                              Icons.logout_rounded,
                              size: 18,
                              color: AppColors.secondary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'התנתקות',
                            style: GoogleFonts.heebo(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const Spacer(),

                  // Physical top left (end of row in RTL): Brand mark + LTR Brand Text
                  Row(
                    textDirection: TextDirection.ltr,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const PirsumotoRelayMark(size: 26),
                      const SizedBox(width: 8),
                      Text(
                        'Pirsumoto Relay',
                        textDirection: TextDirection.ltr,
                        style: GoogleFonts.heebo(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.onSurface,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Error Banner
            if (_error != null)
              Container(
                margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.errorSoft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: GoogleFonts.heebo(
                          color: AppColors.error,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16, color: AppColors.error),
                      onPressed: () => setState(() => _error = null),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),

            // Main Scrollable Area
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Heading & Subtitle
                    Text(
                      'המכשירים שלי',
                      textAlign: TextAlign.right,
                      style: GoogleFonts.heebo(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'הקמפיין הבא מתחיל כאן.',
                      textAlign: TextAlign.right,
                      style: GoogleFonts.heebo(
                        fontSize: 15,
                        color: AppColors.secondary,
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Search Field
                    Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: TextField(
                        controller: _searchController,
                        textDirection: TextDirection.rtl,
                        style: GoogleFonts.heebo(
                          fontSize: 15,
                          color: AppColors.onSurface,
                        ),
                        decoration: InputDecoration(
                          hintText: 'חיפוש מכשיר',
                          hintTextDirection: TextDirection.rtl,
                          hintStyle: GoogleFonts.heebo(
                            color: AppColors.secondary.withValues(alpha: 0.7),
                            fontSize: 14,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            color: AppColors.secondary,
                            size: 22,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18, color: AppColors.secondary),
                                  onPressed: () => _searchController.clear(),
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Manual Device ID Toggle Option
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        InkWell(
                          onTap: () => setState(() => _showManualInput = !_showManualInput),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _showManualInput ? Icons.expand_less_rounded : Icons.add_circle_outline_rounded,
                                  size: 16,
                                  color: AppColors.secondary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _showManualInput ? 'סגור הזנה ידנית' : 'התחברות לפי מזהה ידני',
                                  style: GoogleFonts.heebo(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.secondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (_showManualInput) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'הזנת מזהה מכשיר ישיר (Device ID):',
                              textAlign: TextAlign.right,
                              style: GoogleFonts.heebo(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.onSurface,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _customDeviceIdController,
                              textDirection: TextDirection.ltr,
                              style: GoogleFonts.heebo(fontSize: 14),
                              decoration: InputDecoration(
                                hintText: 'לדוגמה: mdm_device_01',
                                hintTextDirection: TextDirection.ltr,
                                filled: true,
                                fillColor: AppColors.surfaceSubtle,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: AppColors.border),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 40,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _connectToDevice(
                                        deviceId: _customDeviceIdController.text.trim(),
                                        sessionType: 'chat',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.primarySoft,
                                        foregroundColor: AppColors.primaryAction,
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                      ),
                                      icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                                      label: Text(
                                        'צ׳אט',
                                        style: GoogleFonts.heebo(fontWeight: FontWeight.w600, fontSize: 13),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: SizedBox(
                                    height: 40,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _connectToDevice(
                                        deviceId: _customDeviceIdController.text.trim(),
                                        sessionType: 'remote_control',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.primaryAction,
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                      ),
                                      icon: const Icon(Icons.screen_share_outlined, size: 16),
                                      label: Text(
                                        'שליטה מרחוק',
                                        style: GoogleFonts.heebo(fontWeight: FontWeight.w600, fontSize: 13),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),

                    // Devices Stream
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('remote_control_devices')
                          .where('ownerUid', isEqualTo: currentUid)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppColors.primaryAction,
                              ),
                            ),
                          );
                        }

                        final allDocs = snapshot.data?.docs ?? [];
                        final docs = allDocs.where((doc) {
                          if (_searchQuery.isEmpty) return true;
                          final data = doc.data();
                          final model = (data['modelName'] as String? ?? '').toLowerCase();
                          final id = (data['deviceId'] as String? ?? doc.id).toLowerCase();
                          final os = (data['os'] as String? ?? '').toLowerCase();
                          return model.contains(_searchQuery) ||
                              id.contains(_searchQuery) ||
                              os.contains(_searchQuery);
                        }).toList();

                        // Count line (e.g. "3 מכשירים • 2 מחוברים")
                        final totalCount = docs.length;
                        final onlineCount = docs.where((d) {
                          final st = (d.data()['status'] as String? ?? '').toLowerCase();
                          return st == 'online' || st == 'idle' || st == 'ready';
                        }).length;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Device count label
                            if (totalCount > 0)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  '$totalCount מכשירים • $onlineCount מחוברים',
                                  textAlign: TextAlign.right,
                                  style: GoogleFonts.heebo(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.secondary,
                                  ),
                                ),
                              ),

                            if (docs.isEmpty)
                              _buildEmptyState()
                            else
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: docs.length,
                                separatorBuilder: (context, index) => const SizedBox(height: 12),
                                itemBuilder: (context, index) {
                                  final data = docs[index].data();
                                  final deviceId = data['deviceId'] as String? ?? docs[index].id;
                                  final modelName = data['modelName'] as String? ?? 'מכשיר אנדרואיד';
                                  final status = data['status'] as String? ?? 'idle';
                                  final osType = (data['os'] as String? ?? 'android').toLowerCase();
                                  final contextSubtitle = data['contextTitle'] as String? ??
                                      (osType.contains('win')
                                          ? 'מחשב ראשי - Windows'
                                          : (osType.contains('mac')
                                              ? 'מחשב משרד - macOS'
                                              : 'מכשיר נייד - Android'));

                                  final isConnectingThis = _connectingDeviceId == deviceId;
                                  final isBusy = _connectingDeviceId != null;

                                  return _buildDeviceTile(
                                    deviceId: deviceId,
                                    modelName: modelName,
                                    subtitle: contextSubtitle,
                                    status: status,
                                    osType: osType,
                                    isConnectingRemote: isConnectingThis && _connectingType == 'remote_control',
                                    isConnectingChat: isConnectingThis && _connectingType == 'chat',
                                    isDisabled: isBusy && !isConnectingThis,
                                    onConnectRemote: () => _connectToDevice(
                                      deviceId: deviceId,
                                      modelName: modelName,
                                      sessionType: 'remote_control',
                                    ),
                                    onConnectChat: () => _connectToDevice(
                                      deviceId: deviceId,
                                      modelName: modelName,
                                      sessionType: 'chat',
                                    ),
                                  );
                                },
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(28),
      margin: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.devices_other_rounded,
            size: 48,
            color: AppColors.secondary,
          ),
          const SizedBox(height: 14),
          Text(
            _searchQuery.isNotEmpty ? 'לא נמצאו מכשירים התואמים לחיפוש' : 'אין עדיין מכשירים מחוברים',
            textAlign: TextAlign.center,
            style: GoogleFonts.heebo(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _searchQuery.isNotEmpty
                ? 'נסה חיפוש במילה אחרת או נקה את שורת החיפוש.'
                : 'התחבר עם מכשיר פרסומוטו לאותו החשבון או השתמש בהזנה ידנית למעלה.',
            textAlign: TextAlign.center,
            style: GoogleFonts.heebo(
              fontSize: 13,
              color: AppColors.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile({
    required String deviceId,
    required String modelName,
    required String subtitle,
    required String status,
    required String osType,
    required bool isConnectingRemote,
    required bool isConnectingChat,
    required bool isDisabled,
    required VoidCallback onConnectRemote,
    required VoidCallback onConnectChat,
  }) {
    final isOnline = status == 'online' || status == 'idle' || status == 'ready' || status == 'connected';
    final isBusy = status == 'busy' || status == 'in_call' || status == 'streaming';

    // Status Badge Configuration
    Color? badgeBg;
    Color? badgeTextColor;
    String? badgeLabel;
    if (isOnline) {
      badgeBg = AppColors.successSoft;
      badgeTextColor = AppColors.success;
      badgeLabel = 'מחובר';
    } else if (isBusy) {
      badgeBg = AppColors.warningSoft;
      badgeTextColor = AppColors.warning;
      badgeLabel = 'בשימוש';
    }

    // OS Symbol Configuration
    IconData osIcon;
    Color osColor;
    Color osBg;
    if (osType.contains('win')) {
      osIcon = Icons.window_rounded;
      osColor = AppColors.windows;
      osBg = AppColors.windows.withValues(alpha: 0.1);
    } else if (osType.contains('mac') || osType.contains('apple') || osType.contains('ios')) {
      osIcon = Icons.apple_rounded;
      osColor = AppColors.mac;
      osBg = AppColors.mac.withValues(alpha: 0.12);
    } else {
      osIcon = Icons.android_rounded;
      osColor = AppColors.android;
      osBg = AppColors.android.withValues(alpha: 0.12);
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.onSurface.withValues(alpha: 0.035),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Row: OS icon on right, Details in middle, Badge on left
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // OS Icon (physical right in RTL)
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: osBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(osIcon, color: osColor, size: 28),
              ),
              const SizedBox(width: 12),

              // Device Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      modelName,
                      style: GoogleFonts.heebo(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: GoogleFonts.heebo(
                        fontSize: 12.5,
                        color: AppColors.secondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      deviceId,
                      textDirection: TextDirection.ltr,
                      style: GoogleFonts.heebo(
                        fontSize: 11,
                        color: AppColors.secondary.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),

              // Status Badge (physical left in RTL) - only shown when online / in use
              if (badgeLabel != null && badgeBg != null && badgeTextColor != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: badgeTextColor,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        badgeLabel,
                        style: GoogleFonts.heebo(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: badgeTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),

          const SizedBox(height: 14),

          // Action Buttons: In RTL, "צ׳אט" on right, "שליטה מרחוק" on left
          Row(
            children: [
              // Chat Button (Right in RTL reading order)
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: isDisabled || isConnectingChat ? null : onConnectChat,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primarySoft,
                      foregroundColor: AppColors.primaryAction,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: isConnectingChat
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryAction),
                          )
                        : const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                    label: Text(
                      'צ׳אט',
                      style: GoogleFonts.heebo(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 10),

              // Remote Control Button (Left in RTL reading order)
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: isDisabled || isConnectingRemote ? null : onConnectRemote,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppColors.surface,
                      foregroundColor: AppColors.primaryAction,
                      side: const BorderSide(
                        color: AppColors.primaryAction,
                        width: 1,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: isConnectingRemote
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryAction),
                          )
                        : const Icon(Icons.screen_share_outlined, size: 18),
                    label: Text(
                      'שליטה מרחוק',
                      style: GoogleFonts.heebo(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
