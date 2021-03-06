import 'dart:ui';

import 'media_stream.dart';
import 'media_stream_track.dart';

abstract class MediaRecorder {
  /// For Android use audioChannel param
  /// For iOS use audioTrack
  Future<void> start(String path,
      {MediaStreamTrack? videoTrack, bool audioOnly = false, Size? videoSize});

  /// Only for Flutter Web
  void startWeb(
    MediaStream stream, {
    Function(dynamic blob, bool isLastOne)? onDataChunk,
    String? mimeType,
    bool mirror = true,
  });

  Future<dynamic> stop();

  bool canStartWeb(MediaStream mediaStream, {String mimeType = 'video/webm'});
}
