import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import '../signaling/controller_signaling.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'remote_control_screen.dart';
import 'whatsapp_chat_screen.dart';

class DeviceSelectScreen extends StatefulWidget {
  const DeviceSelectScreen({super.key});

  @override
  State<DeviceSelectScreen> createState() => _DeviceSelectScreenState();
}

class _DeviceSelectScreenState extends State<DeviceSelectScreen> {
  final TextEditingController _customDeviceIdController = TextEditingController();
  final TextEditingController _controllerNameController = TextEditingController();
  String? _connectingDeviceId;
  String? _connectingType;
  String? _error;
  bool _showManualInput = false;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _controllerNameController.text = user?.displayName ??
        user?.email?.split('@').first ??
        'Controller';
  }

  @override
  void dispose() {
    _customDeviceIdController.dispose();
    _controllerNameController.dispose();
    super.dispose();
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

      // Initiate WebRTC connection
      session.connect();

      if (!mounted) return;

      setState(() {
        _connectingDeviceId = null;
        _connectingType = null;
      });

      final displayName = (modelName != null && modelName.isNotEmpty)
          ? '$modelName ($deviceId)'
          : 'מכשיר פרסומוטו ($deviceId)';

      if (sessionType == 'chat') {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => WhatsAppChatScreen(
              session: session,
              deviceName: displayName,
            ),
          ),
        );
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RemoteControlScreen(
              session: session,
              deviceName: displayName,
            ),
          ),
        );
      }
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
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF30363D)),
        ),
        title: Text(
          'התנתקות',
          style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'האם אתה בטוח שברצונך להתנתק מהחשבון?',
          style: GoogleFonts.inter(color: const Color(0xFFC9D1D9)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('ביטול', style: GoogleFonts.inter(color: const Color(0xFF8B949E))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDA3633),
              foregroundColor: Colors.white,
            ),
            child: Text('התנתק', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
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
      backgroundColor: const Color(0xFF0A0E17),
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar / User Profile
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                color: Color(0xFF161B22),
                border: Border(
                  bottom: BorderSide(color: Color(0xFF30363D), width: 1),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF2563EB), Color(0xFF7C3AED)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.screen_share_rounded,
                      size: 22,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'פרסומוטו Remote Control',
                          style: GoogleFonts.outfit(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          currentUser?.email ?? 'מחובר',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: const Color(0xFF8B949E),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _signOut,
                    tooltip: 'התנתק מהחשבון',
                    icon: const Icon(Icons.logout_rounded, color: Color(0xFF8B949E)),
                  ),
                ],
              ),
            ),

            if (_error != null)
              Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: GoogleFonts.inter(color: Colors.redAccent, fontSize: 13),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                      onPressed: () => setState(() => _error = null),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),

            // Content Area
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'המכשירים שלך',
                          style: GoogleFonts.outfit(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            setState(() => _showManualInput = !_showManualInput);
                          },
                          icon: Icon(
                            _showManualInput ? Icons.devices_rounded : Icons.keyboard,
                            size: 16,
                            color: const Color(0xFF58A6FF),
                          ),
                          label: Text(
                            _showManualInput ? 'הצג רשימה' : 'הזנה ידנית',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color: const Color(0xFF58A6FF),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'רשימת מכשירי האנדרואיד המחוברים לאותו החשבון',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: const Color(0xFF8B949E),
                      ),
                    ),
                    const SizedBox(height: 18),

                    // Manual input section (if toggled)
                    if (_showManualInput) ...[
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF161B22),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF30363D)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'התחברות לפי מזהה מכשיר (Device ID):',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFFC9D1D9),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _customDeviceIdController,
                              style: GoogleFonts.inter(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'לדוגמה: mdm_device_01',
                                hintStyle: GoogleFonts.inter(color: const Color(0xFF484F58)),
                                filled: true,
                                fillColor: const Color(0xFF0D1117),
                                prefixIcon: const Icon(Icons.phone_android, color: Color(0xFF58A6FF)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFF30363D)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFF30363D)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 46,
                                    child: ElevatedButton.icon(
                                      onPressed: _connectingDeviceId != null
                                          ? null
                                          : () => _connectToDevice(
                                                deviceId: _customDeviceIdController.text.trim(),
                                                sessionType: 'chat',
                                              ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF00A884),
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      icon: const Icon(Icons.chat_rounded, size: 18),
                                      label: Text(
                                        'צ\'אט (WhatsApp)',
                                        style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: SizedBox(
                                    height: 46,
                                    child: ElevatedButton.icon(
                                      onPressed: _connectingDeviceId != null
                                          ? null
                                          : () => _connectToDevice(
                                                deviceId: _customDeviceIdController.text.trim(),
                                                sessionType: 'remote_control',
                                              ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF238636),
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      icon: const Icon(Icons.touch_app_rounded, size: 18),
                                      label: Text(
                                        'שליטה מרחוק',
                                        style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // Devices Stream from remote_control_devices collection filtered by ownerUid
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
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            ),
                          );
                        }

                        final docs = snapshot.data?.docs ?? [];

                        if (docs.isEmpty) {
                          return _buildEmptyState(currentUser?.email);
                        }

                        return ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: docs.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 14),
                          itemBuilder: (context, index) {
                            final data = docs[index].data();
                            final deviceId = data['deviceId'] as String? ?? docs[index].id;
                            final modelName = data['modelName'] as String? ?? 'מכשיר אנדרואיד';
                            final status = data['status'] as String? ?? 'idle';
                            final isConnectingThis = _connectingDeviceId == deviceId;
                            final isBusy = _connectingDeviceId != null;

                            return _buildDeviceCard(
                              deviceId: deviceId,
                              modelName: modelName,
                              status: status,
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

  Widget _buildDeviceCard({
    required String deviceId,
    required String modelName,
    required String status,
    required bool isConnectingRemote,
    required bool isConnectingChat,
    required bool isDisabled,
    required VoidCallback onConnectRemote,
    required VoidCallback onConnectChat,
  }) {
    Color statusColor;
    String statusText;
    switch (status) {
      case 'active':
        statusColor = const Color(0xFF58A6FF);
        statusText = 'בשימוש פעיל';
        break;
      case 'idle':
        statusColor = const Color(0xFF3FB950);
        statusText = 'זמין להתחברות';
        break;
      case 'offline':
      default:
        statusColor = const Color(0xFF8B949E);
        statusText = 'לא מקוון';
        break;
    }

    final isConnectingAny = isConnectingRemote || isConnectingChat;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isConnectingAny ? const Color(0xFF00A884) : const Color(0xFF30363D),
          width: isConnectingAny ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFF21262D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF30363D)),
                ),
                child: const Icon(
                  Icons.phone_android_rounded,
                  color: Color(0xFF58A6FF),
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      modelName,
                      style: GoogleFonts.outfit(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'מזהה: $deviceId',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF8B949E),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: statusColor.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusText,
                      style: GoogleFonts.inter(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Action Tile Buttons: WhatsApp Chat + Remote Control
          Row(
            children: [
              // Chat (WhatsApp) Button
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: isDisabled || isConnectingAny ? null : onConnectChat,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A884),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                    ),
                    icon: isConnectingChat
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.chat_rounded, size: 18),
                    label: Text(
                      isConnectingChat ? 'מתחבר...' : 'צ\'אט (WhatsApp)',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Remote Control Button
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: isDisabled || isConnectingAny ? null : onConnectRemote,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF21262D),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF30363D)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                    ),
                    icon: isConnectingRemote
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.touch_app_rounded, size: 18, color: Color(0xFF58A6FF)),
                    label: Text(
                      isConnectingRemote ? 'מתחבר...' : 'שליטה מרחוק',
                      style: GoogleFonts.inter(
                        fontSize: 13,
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

  Widget _buildEmptyState(String? email) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.phone_android_outlined,
              size: 36,
              color: Color(0xFF8B949E),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'לא נמצאו מכשירים פעילים',
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'כדי לשלוט במכשיר, פתח את אפליקציית Pirsumoto במכשיר האנדרואיד שלך והתחבר עם החשבון:\n${email ?? ""}',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: const Color(0xFF8B949E),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _showManualInput = true;
                _customDeviceIdController.text = 'mdm_device_01';
              });
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF58A6FF),
              side: const BorderSide(color: Color(0xFF30363D)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.dialpad, size: 16),
            label: Text(
              'התחבר ידנית עם מזהה מכשיר',
              style: GoogleFonts.inter(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
