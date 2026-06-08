import 'dart:typed_data';
// import 'package:flutter_gemma/flutter_gemma.dart';

class GemmaService {
  Future<void> downloadGemmaModel({Function(int)? onProgress}) async {
    // Commented out to reduce APK size
    /*
    final modelUrl =
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm';

    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(modelUrl).withProgress((progress) {
      print('Downloading: $progress%');
      if (onProgress != null) onProgress(progress);
    }).install();

    print('Model downloaded and installed successfully!');
    */
  }

  Future<String?> askGemmaAboutImage(
    Uint8List imageBytes,
    String hebrewPrompt,
  ) async {
    // Commented out to reduce APK size
    return null;
    /*
    await downloadGemmaModel();

    final model = await FlutterGemma.getActiveModel(
      maxTokens: 2048,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
    );

    final chat = await model.createChat();

    print('GemmaService: Preparing to send message with image.');
    print('GemmaService: Image size in bytes: ${imageBytes.lengthInBytes}');
    
    final prompt = "<image>\\nWhat text is visible in this image? Please list it clearly. If you see an app interface, describe it.";
    print('GemmaService: Prompt text: $prompt');
    
    await chat.addQueryChunk(
      Message.withImage(
        text: prompt,
        imageBytes: imageBytes,
        isUser: true,
      ),
    );

    print('GemmaService: Generation started...');
    final response = await chat.generateChatResponse();
    if (response is TextResponse) {
      print('Gemma says: ${response.token}');
      return response.token;
    } else {
      print('Gemma returned a non-text response: $response');
      return null;
    }
    */
  }
}
