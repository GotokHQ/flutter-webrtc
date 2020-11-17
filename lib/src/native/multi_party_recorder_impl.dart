import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import '../interface/media_recorder.dart';
import '../interface/media_stream.dart';
import '../interface/media_stream_track.dart';
import '../interface/utils.dart';
import 'utils.dart';

class MediaRecorderNative extends MediaRecorder {
  MediaRecorderNative({
    int fps,
    bool audioOnly,
    MediaFormat format,
    Size videoSize,
  }) : super(
            fps: fps,
            audioOnly: audioOnly,
            format: format,
            videoSize: videoSize) {
    _initialize();
  }

  static MethodChannel _channel = WebRTC.methodChannel();
  static final _random = Random();
  final _recorderId = _random.nextInt(0x7FFFFFFF);
  bool running = false;
  bool _isReleased = false;
  StreamSubscription<dynamic> _eventSubscription;
  Completer<void> _creatingCompleter;
  Map<String, VideoTrackObserver> _videoTrackObservers =
      <String, VideoTrackObserver>{};
  String _filePath;
  Future<void> _initialize() async {
    if (_isReleased) {
      return Future<void>.value();
    }
    try {
      _creatingCompleter = Completer<void>();
      final isInitialized = await _channel.invokeMethod('createMediaRecorder', {
        'width': videoSize.width,
        'height': videoSize.height,
        'type': MediaRecorder.stringFromMediaRecorderType(type),
        'audioOnly': audioOnly,
        'fps': fps,
        'recorderId': _recorderId,
        'format': MediaRecorder.stringFromMediaFormat(format)
      });
      if (!isInitialized) {
        throw RecorderException(
            'initialization_failed', 'could not intitialize media recorder');
      }
      value = value.copyWith(
        isInitialized: isInitialized,
        videoSize: Size(
          videoSize.width,
          videoSize.height,
        ),
      );
    } on PlatformException catch (e) {
      throw RecorderException(e.code, e.message);
    }
    _eventSubscription = _eventChannelFor(_recorderId)
        .receiveBroadcastStream()
        .listen(_listener, onError: errorListener);
    _creatingCompleter.complete();
    return _creatingCompleter.future;
  }

  @override
  Future<void> addVideoTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    try {
      final connected = await _channel.invokeMethod('addTrackToMediaRecorder', {
        'trackId': track.id,
        'recorderId': _recorderId,
      });
      if (connected) {
        _videoTrackObservers[track.id] = VideoTrackObserver(this, track);
      } else {
        throw RecorderException(
          'Connection Failed',
          'failed to add track:${track.id} to media recorde:$_recorderId}',
        );
      }
    } on PlatformException catch (e) {
      throw RecorderException(e.code, e.message);
    }
  }

  @override
  Future<void> removeVideoTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    try {
      await _channel.invokeMethod('removeTrackFromMediaRecorder', {
        'trackId': track?.id,
        'recorderId': _recorderId,
      });
      _videoTrackObservers.remove(track?.id);
    } on PlatformException catch (e) {
      throw RecorderException(e.code, e.message);
    }
  }

  @override
  Future<void> setPaused(bool paused) async {
    print('value.isPaused is ${value.isPaused}');
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MediaRecorder',
        'resume was called on uninitialized MediaRecorder',
      );
    }
    if (!value.isRecordingVideo) {
      throw RecorderException(
        'A video recording is not started.',
        'set pause was called when a recording that was not started.',
      );
    }
    if (value.isPaused == paused) {
      return;
    }
    try {
      // ignore: prefer_single_quotes
      print("setPaused with $paused");
      await _channel.invokeMethod('pauseMediaRecorder',
          <String, dynamic>{'recorderId': _recorderId, 'paused': paused});
      value = value.copyWith(isPaused: paused);
    } on PlatformException catch (e) {
      throw RecorderException(e.code, e.message);
    }
  }

  @override
  Future<void> start(String filePath) async {
    assert(filePath != null);
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MediaRecorder',
        'startVideoRecording was called on uninitialized MediaRecorder',
      );
    }
    if (value.isRecordingVideo) {
      throw RecorderException(
        'A video recording is already started.',
        'startVideoRecording was called when a recording is already started.',
      );
    }

    try {
      print('should start media recorder');
      await _channel.invokeMethod('startMediaRecorder',
          <String, dynamic>{'path': filePath, 'recorderId': _recorderId});
      _filePath = filePath;
      value = value.copyWith(isRecordingVideo: true);
      print('media_recorder_started:${value.isRecordingVideo}');
    } on PlatformException catch (e) {
      throw RecorderException(e.code, e.message);
    }
  }

  @override
  Future<void> startWeb(
    MediaStream stream, {
    Function(dynamic blob, bool isLastOne) onDataChunk,
  }) async {}

  /// Stop recording.

  @override
  Future<MediaRecorderMetaData> stop(
      {returnMetaData = false,
      metaDataOptions = const MetaDataOptions(
          isAudioOnly: false,
          thumbnailHeight: 200,
          thumbnailWidth: 200,
          thumbnailQuality: 0.7)}) async {
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MediaRecorder',
        'stopVideoRecording was called on uninitialized MediaRecorder',
      );
    }
    if (!value.isRecordingVideo) {
      throw RecorderException(
        'No video is recording',
        'stopVideoRecording was called when no video is recording.',
      );
    }
    try {
      value = value.copyWith(isRecordingVideo: false);
      final args = <String, dynamic>{
        'recorderId': _recorderId,
        'returnMetaData': returnMetaData,
      };
      if (returnMetaData) {
        args['metaDataOptions'] = metaDataOptions?.toMap();
      }
      final result = await _channel.invokeMethod(
        'stopMediaRecorder',
        args,
      );
      if (result != null) {
        return MediaRecorderMetaData.fromMap(asStringKeyedMap(result))
            .copyWith(url: _filePath);
      }
      return null;
    } on PlatformException catch (e) {
      throw RecorderException(e.code, e.message);
    }
  }

  @override
  bool operator ==(dynamic other) {
    if (identical(this, other)) return true;
    if (runtimeType != other.runtimeType) return false;
    return other.hashCode == hashCode;
  }

  @override
  int get hashCode => _recorderId.hashCode ^ videoSize.hashCode;

  @override
  Future<void> dispose() async {
    await release();
    super.dispose();
  }

  @override
  Future<void> release() async {
    if (_isReleased) {
      return;
    }
    if (_creatingCompleter != null) {
      await _creatingCompleter.future;
      await _eventSubscription?.cancel();
      await _channel.invokeMethod(
        'disposeMediaRecorder',
        <String, dynamic>{'recorderId': _recorderId},
      );
    }
    _isReleased = true;
    value = RecorderValue.uninitialized();
  }

  EventChannel _eventChannelFor(int recorderId) {
    return EventChannel('FlutterWebRTC/mediaRecorderEvents/$recorderId');
  }

  void _listener(dynamic event) {
    final Map<dynamic, dynamic> map = event;
    if (_isReleased) {
      return;
    }
    switch (map['eventType']) {
      case 'error':
        value = value.copyWith(errorDescription: event['errorDescription']);
        break;
    }
  }

  void errorListener(Object obj) {
    final PlatformException e = obj;
    throw e;
  }
}
