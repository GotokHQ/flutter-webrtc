import 'dart:async';
import 'dart:math';
import 'dart:ui';

import '../interface/enums.dart';
import '../interface/media_recorder.dart';
import '../interface/media_stream.dart';
import '../interface/media_stream_track.dart';
import 'utils.dart';

class MediaRecorderNative extends MediaRecorder {
  static final _random = Random();
  final _recorderId = _random.nextInt(0x7FFFFFFF);

  @override
  Future<void> start(String path,
      {MediaStreamTrack videoTrack, bool audioOnly = false, Size videoSize
      // TODO(cloudwebrtc): add codec/quality options
      }) async {
    assert(audioOnly != null);
    if (path == null) {
      throw ArgumentError.notNull('path');
    }

    if (!audioOnly && videoTrack == null) {
      throw Exception('Neither audio nor video track were provided');
    }

    await WebRTC.methodChannel().invokeMethod('startRecordToFile', {
      'path': path,
      'audioOnly': audioOnly,
      'videoTrackId': videoTrack?.id,
      'recorderId': _recorderId,
      'width': videoSize?.width ?? 0,
      'height': videoSize?.height ?? 0,
    });
  }

  @override
  void startWeb(MediaStream stream,
      {Function(dynamic blob, bool isLastOne) onDataChunk, String mimeType}) {
    throw 'It\'s for Flutter Web only';
  }

  @override
  Future<dynamic> stop() async => await WebRTC.methodChannel()
      .invokeMethod('stopRecordToFile', {'recorderId': _recorderId});

  @override
  bool canStartWeb(MediaStream mediaStream, {String mimeType = 'video/webm'}) {
    return false;
  }
}
