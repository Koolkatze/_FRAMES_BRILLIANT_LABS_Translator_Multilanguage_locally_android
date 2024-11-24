import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart';
import 'download_progress_state.dart';
import 'download_assets.dart';
import 'package:buffered_list_stream/buffered_list_stream.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:logging/logging.dart';
import 'package:record/record.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/tx/plain_text.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class LanguageConfig {
  final TranslateLanguage mlKitLang;
  final String voskModel;
  final String displayName;

  const LanguageConfig(this.mlKitLang, this.voskModel, this.displayName);
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint(
          '${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  // Language configurations
  static final Map<String, LanguageConfig> supportedLanguages = {
    'Arabic': const LanguageConfig(TranslateLanguage.arabic,
        'vosk-model-small-ar-tn-0.1-linto.zip', 'Arabic'),
    'Catalan': const LanguageConfig(
        TranslateLanguage.catalan, 'vosk-model-small-ca-0.4.zip', 'Catalan'),
    'Chinese': const LanguageConfig(
        TranslateLanguage.chinese, 'vosk-model-small-cn-0.22.zip', 'Chinese'),
    'Czech': const LanguageConfig(TranslateLanguage.czech,
        'vosk-model-small-cs-0.4-rhasspy.zip', 'Czech'),
    'German': const LanguageConfig(
        TranslateLanguage.german, 'vosk-model-small-de-0.15.zip', 'German'),
    'English (India)': const LanguageConfig(TranslateLanguage.english,
        'vosk-model-small-en-in-0.4.zip', 'English (India)'),
    'English': const LanguageConfig(TranslateLanguage.english,
        'vosk-model-small-en-us-0.15.zip', 'English'),
    'Spanish': const LanguageConfig(
        TranslateLanguage.spanish, 'vosk-model-small-es-0.42.zip', 'Spanish'),
    'French': const LanguageConfig(TranslateLanguage.french,
        'vosk-model-small-fr-pguyot-0.3.zip', 'French'),
    'Hindi': const LanguageConfig(
        TranslateLanguage.hindi, 'vosk-model-small-hi-0.22.zip', 'Hindi'),
    'Italian': const LanguageConfig(
        TranslateLanguage.italian, 'vosk-model-small-it-0.22.zip', 'Italian'),
    'Japanese': const LanguageConfig(
        TranslateLanguage.japanese, 'vosk-model-small-ja-0.22.zip', 'Japanese'),
    'Korean': const LanguageConfig(
        TranslateLanguage.korean, 'vosk-model-small-ko-0.22.zip', 'Korean'),
    'Dutch': const LanguageConfig(
        TranslateLanguage.dutch, 'vosk-model-small-nl-0.22.zip', 'Dutch'),
    'Portuguese': const LanguageConfig(TranslateLanguage.portuguese,
        'vosk-model-small-pt-0.3.zip', 'Portuguese'),
    'Russian': const LanguageConfig(
        TranslateLanguage.russian, 'vosk-model-small-ru-0.22.zip', 'Russian'),
    'Turkish': const LanguageConfig(
        TranslateLanguage.turkish, 'vosk-model-small-tr-0.3.zip', 'Turkish'),
    'Ukrainian': const LanguageConfig(TranslateLanguage.ukrainian,
        'vosk-model-small-uk-v3-small.zip', 'Ukrainian'),
    'Vietnamese': const LanguageConfig(TranslateLanguage.vietnamese,
        'vosk-model-small-vn-0.4.zip', 'Vietnamese'),
  };

  String _sourceLanguage = 'Spanish';
  String _targetLanguage = 'Italian';

  final _vosk = VoskFlutterPlugin.instance();
  late Model _model;
  late Recognizer _recognizer;
  static const _sampleRate = 16000;

  String _text = "N/A";
  String _translatedText = "N/A";

  late OnDeviceTranslator _translator;

  @override
  void initState() {
    runApp(const DownloadProgressPage());
    super.initState();
    tryScanAndConnectAndStart(andRun: true);
    _initTranslator();
    _initVosk();
  }

  void _initTranslator() {
    _translator = OnDeviceTranslator(
      sourceLanguage: supportedLanguages[_sourceLanguage]!.mlKitLang,
      targetLanguage: supportedLanguages[_targetLanguage]!.mlKitLang,
    );
  }

  @override
  void dispose() async {
    _model.dispose();
    _recognizer.dispose();
    _translator.close();
    super.dispose();
  }

  void _initVosk() async {
    final modelPath = await ModelLoader().loadFromAssets(
        'assets/${supportedLanguages[_sourceLanguage]!.voskModel}');
    _model = await _vosk.createModel(modelPath);
    _recognizer =
        await _vosk.createRecognizer(model: _model, sampleRate: _sampleRate);
  }

  Future<void> _changeLanguages(
      String? newSourceLang, String? newTargetLang) async {
    if (currentState == ApplicationState.running) {
      await cancel();
    }

    setState(() {
      if (newSourceLang != null) _sourceLanguage = newSourceLang;
      if (newTargetLang != null) _targetLanguage = newTargetLang;
    });

    // Reinitialize translator and Vosk with new languages
    await _translator.close();
    _initTranslator();
    _model.dispose();
    _recognizer.dispose();
    _initVosk();
  }

  /// Sets up the Audio used for the application.
  /// Returns true if the audio is set up correctly, in which case
  /// it also returns a reference to the AudioRecorder and the
  /// audioSampleBufferedStream
  Future<(bool, AudioRecorder?, Stream<List<int>>?)> startAudio() async {
    // create a fresh AudioRecorder each time we run - it will be dispose()d when we click stop
    AudioRecorder audioRecorder = AudioRecorder();

    // Check and request permission if needed
    if (!await audioRecorder.hasPermission()) {
      return (false, null, null);
    }

    try {
      // start the audio stream
      // TODO select suitable sample rate for the Frame given BLE bandwidth constraints if we want to switch to Frame mic
      final recordStream = await audioRecorder.startStream(const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate));

      // buffer the audio stream into chunks of 4096 samples
      final audioSampleBufferedStream = bufferedListStream(
        recordStream.map((event) {
          return event.toList();
        }),
        // samples are PCM16, so 2 bytes per sample
        4096 * 2,
      );

      return (true, audioRecorder, audioSampleBufferedStream);
    } catch (e) {
      _log.severe('Error starting Audio: $e');
      return (false, null, null);
    }
  }

  Future<void> stopAudio(AudioRecorder recorder) async {
    // stop the audio
    await recorder.stop();
    await recorder.dispose();
  }

  /// This application uses vosk speech-to-text to listen to audio from the host mic in a selected
  /// source language, convert to text, translate the text to the target language,
  /// and send the text to the Frame in real-time. It has a running main loop in this function
  /// and also on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    _text = '';
    _translatedText = '';
    if (mounted) setState(() {});

    try {
      var (ok, audioRecorder, audioSampleBufferedStream) = await startAudio();
      if (!ok) {
        currentState = ApplicationState.ready;
        if (mounted) setState(() {});
        return;
      }

      String prevText = '';

      // loop over the incoming audio data and send reults to Frame
      await for (var audioSample in audioSampleBufferedStream!) {
        // if the user has clicked Stop we want to jump out of the main loop and stop processing
        if (currentState != ApplicationState.running) {
          break;
        }

        // recognizer blocks until it has something
        final resultReady = await _recognizer
            .acceptWaveformBytes(Uint8List.fromList(audioSample));

        // TODO consider enabling "alternatives"?
        _text = resultReady
            ? jsonDecode(await _recognizer.getResult())['text']
            : jsonDecode(await _recognizer.getPartialResult())['partial'];

        // If the text is the same as the previous one, we don't send it to Frame and force a redraw
        // The recognizer often produces a bunch of empty string in a row too, so this means
        // we send the first one (clears the display) but not subsequent ones
        // Often the final result matches the last partial, so if it's a final result then show it
        // on the phone but don't send it
        if (_text == prevText) {
          continue;
        } else if (_text.isEmpty) {
          // turn the empty string into a single space and send
          // still can't put it through the wrapped-text-chunked-sender
          // because it will be zero bytes payload so no message will
          // be sent.
          // Users might say this first empty partial
          // comes a bit soon and hence the display is cleared a little sooner
          // than they want (not like audio hangs around in the air though
          // after words are spoken!)
          await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: ' '));
          prevText = '';
          continue;
        } else {
          _translatedText = await _translator.translateText(_text);
        }

        if (_log.isLoggable(Level.FINE)) {
          _log.fine('Recognized text: $_text');
        }

        // send current text to Frame
        String wrappedText =
            TextUtils.wrapText(_translatedText, 640, 4).join('\n');
        await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: wrappedText));

        // update the phone UI too
        if (mounted) setState(() {});
        prevText = _text;
      }

      await stopAudio(audioRecorder!);
    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  /// The run()) function will keep running until we interrupt it here
  /// and tell it to stop listening to audio
  @override
  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Translation',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
            title: const Text("Translation"), actions: [getBatteryWidget()]),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Language selection row
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Source language dropdown
                      Expanded(
                        child: DropdownButton<String>(
                          value: _sourceLanguage,
                          isExpanded: true,
                          items: supportedLanguages.keys
                              .where((lang) => lang != _targetLanguage)
                              .map((String lang) {
                            return DropdownMenuItem<String>(
                              value: lang,
                              child:
                                  Text(lang, overflow: TextOverflow.ellipsis),
                            );
                          }).toList(),
                          onChanged: (String? newValue) {
                            if (newValue != null) {
                              _changeLanguages(newValue, null);
                            }
                          },
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8.0),
                        child: Icon(Icons.arrow_forward),
                      ),
                      // Target language dropdown
                      Expanded(
                        child: DropdownButton<String>(
                          value: _targetLanguage,
                          isExpanded: true,
                          items: supportedLanguages.keys
                              .where((lang) => lang != _sourceLanguage)
                              .map((String lang) {
                            return DropdownMenuItem<String>(
                              value: lang,
                              child:
                                  Text(lang, overflow: TextOverflow.ellipsis),
                            );
                          }).toList(),
                          onChanged: (String? newValue) {
                            if (newValue != null) {
                              _changeLanguages(null, newValue);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(_text, style: const TextStyle(fontSize: 30)),
                const Divider(),
                Text(_translatedText,
                    style: const TextStyle(
                        fontSize: 30, fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ),
        floatingActionButton: getFloatingActionButtonWidget(
            const Icon(Icons.mic), const Icon(Icons.mic_off)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
