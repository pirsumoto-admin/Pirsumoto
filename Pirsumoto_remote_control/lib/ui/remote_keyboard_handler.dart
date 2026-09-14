import 'package:flutter/material.dart';
import '../remote/remote_protocol.dart';

class RemoteKeyboardHandler extends StatefulWidget {
  final Function(String text) onSendText;
  final Function(String key) onSendKey;
  final Widget child;

  const RemoteKeyboardHandler({
    super.key,
    required this.onSendText,
    required this.onSendKey,
    required this.child,
  });

  static RemoteKeyboardHandlerState? of(BuildContext context) {
    return context.findAncestorStateOfType<RemoteKeyboardHandlerState>();
  }

  @override
  State<RemoteKeyboardHandler> createState() => RemoteKeyboardHandlerState();
}

class RemoteKeyboardHandlerState extends State<RemoteKeyboardHandler> {
  final FocusNode _focusNode = FocusNode();
  final TextEditingController _textController = TextEditingController();
  bool _isKeyboardVisible = false;
  bool get isKeyboardVisible => _isKeyboardVisible;

  @override
  void dispose() {
    _focusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  void toggleKeyboard() {
    if (_isKeyboardVisible) {
      hideKeyboard();
    } else {
      showKeyboard();
    }
  }

  void showKeyboard() {
    setState(() => _isKeyboardVisible = true);
    _focusNode.requestFocus();
  }

  void hideKeyboard() {
    setState(() => _isKeyboardVisible = false);
    _focusNode.unfocus();
  }

  void _onTextChanged(String value) {
    if (value.isNotEmpty) {
      widget.onSendText(value);
      _textController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // Invisible input field that connects to the native system keyboard
        Positioned(
          left: -999,
          top: -999,
          child: SizedBox(
            width: 1,
            height: 1,
            child: TextField(
              focusNode: _focusNode,
              controller: _textController,
              autocorrect: false,
              enableSuggestions: true,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.send,
              onChanged: _onTextChanged,
              onSubmitted: (value) {
                if (value.isNotEmpty) {
                  widget.onSendText(value);
                  _textController.clear();
                }
                widget.onSendKey(RemoteProtocolConstants.keyEnter);
              },
            ),
          ),
        ),
      ],
    );
  }
}
