import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../interface/media_stream.dart';
import '../interface/media_stream_track.dart';
import '../interface/multi_party_recorder.dart';
import '../interface/utils.dart';
import 'utils.dart';

class MultiPartyRecorderNative extends MultiPartyRecorder {
  MultiPartyRecorderNative(
      {int? fps,
      bool? audioOnly,
      MediaFormat format = MediaFormat.mpeg4,
      Size? videoSize,
      MultiPartyRecorderType? type = MultiPartyRecorderType.local})
      : super(
            fps: fps,
            audioOnly: audioOnly,
            format: format,
            videoSize: videoSize,
            type: type) {
    _initialize();
  }

  final MethodChannel _channel = WebRTC.methodChannel();
  static final _random = Random();
  final _recorderId = _random.nextInt(0x7FFFFFFF);
  bool running = false;
  bool _isReleased = false;
  late StreamSubscription<dynamic> _eventSubscription;
  late Completer<void> _creatingCompleter;
  final Map<String, VideoTrackObserver> _videoTrackObservers =
      <String, VideoTrackObserver>{};
  late String _filePath;
  Future<void> _initialize() async {
    if (_isReleased) {
      return Future<void>.value();
    }
    try {
      _creatingCompleter = Completer<void>();
      final isInitialized =
          await _channel.invokeMethod('createMultiPartyRecorder', {
        'width': videoSize?.width,
        'height': videoSize?.height,
        'type': MultiPartyRecorder.stringFromMultiPartyRecorderType(type!),
        'audioOnly': audioOnly,
        'fps': fps,
        'recorderId': _recorderId,
        'format': MultiPartyRecorder.stringFromMediaFormat(format!)
      });
      if (!isInitialized) {
        throw RecorderException('initialization_failed',
            description: 'could not intitialize media recorder');
      }
      value = value.copyWith(
        isInitialized: isInitialized,
        videoSize: Size(
          videoSize!.width,
          videoSize!.height,
        ),
      );
    } on PlatformException catch (e) {
      throw RecorderException(e.code, description: e.message);
    }
    _eventSubscription = _eventChannelFor(_recorderId)
        .receiveBroadcastStream()
        .listen(_listener, onError: errorListener);
    _creatingCompleter.complete();
    return _creatingCompleter.future;
  }

  @override
  Future<void> addTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    try {
      final connected =
          await _channel.invokeMethod('addTrackToMultiPartyRecorder', {
        'trackId': track.id,
        'recorderId': _recorderId,
      });
      if (connected) {
        _videoTrackObservers[track.id!] = VideoTrackObserver(this, track);
      } else {
        throw RecorderException(
          'Connection Failed',
          description:
              'failed to add track:${track.id} to media recorde:$_recorderId}',
        );
      }
    } on PlatformException catch (e) {
      throw RecorderException(e.code, description: e.message);
    }
  }

  @override
  Future<void> removeTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    try {
      await _channel.invokeMethod('removeTrackFromMultiPartyRecorder', {
        'trackId': track.id,
        'recorderId': _recorderId,
      });
      _videoTrackObservers.remove(track.id);
    } on PlatformException catch (e) {
      throw RecorderException(e.code, description: e.message);
    }
  }

  @override
  Future<void> setPaused(bool paused) async {
    print('value.isPaused is ${value.isPaused}');
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MultiPartyRecorder',
        description: 'resume was called on uninitialized MultiPartyRecorder',
      );
    }
    if (!value.isRecordingVideo) {
      throw RecorderException(
        'A video recording is not started.',
        description:
            'set pause was called when a recording that was not started.',
      );
    }
    if (value.isPaused == paused) {
      return;
    }
    try {
      // ignore: prefer_single_quotes
      print("setPaused with $paused");
      await _channel.invokeMethod('pauseMultiPartyRecorder',
          <String, dynamic>{'recorderId': _recorderId, 'paused': paused});
      value = value.copyWith(isPaused: paused);
    } on PlatformException catch (e) {
      throw RecorderException(e.code, description: e.message);
    }
  }

  @override
  Future<void> start(String filePath) async {
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MultiPartyRecorder',
        description:
            'startVideoRecording was called on uninitialized MultiPartyRecorder',
      );
    }
    if (value.isRecordingVideo) {
      throw RecorderException(
        'A video recording is already started.',
        description:
            'startVideoRecording was called when a recording is already started.',
      );
    }

    try {
      print('should start media recorder');
      await _channel.invokeMethod('startMultiPartyRecorder',
          <String, dynamic>{'path': filePath, 'recorderId': _recorderId});
      _filePath = filePath;
      value = value.copyWith(isRecordingVideo: true);
      print('media_recorder_started:${value.isRecordingVideo}');
    } on PlatformException catch (e) {
      throw RecorderException(e.code, description: e.message);
    }
  }

  @override
  Future<void> startWeb({
    Function(dynamic blob, bool isLastOne)? onDataChunk,
    String? mimeType,
  }) async {}

  /// Stop recording.

  @override
  Future<MultiPartyRecorderMetaData?> stop(
      {returnMetaData = false,
      metaDataOptions = const MetaDataOptions(
          isAudioOnly: false,
          thumbnailHeight: 200,
          thumbnailWidth: 200,
          thumbnailQuality: 0.7)}) async {
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MultiPartyRecorder',
        description:
            'stopVideoRecording was called on uninitialized MultiPartyRecorder',
      );
    }
    if (!value.isRecordingVideo) {
      throw RecorderException(
        'No video is recording',
        description:
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
        'stopMultiPartyRecorder',
        args,
      );
      if (result != null) {
        return MultiPartyRecorderMetaData.fromMap(asStringKeyedMap(result))
            .copyWith(url: _filePath);
      }
      return null;
    } on PlatformException catch (e) {
      throw RecorderException(e.code, description: e.message);
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
    await _creatingCompleter.future;
    await _eventSubscription.cancel();
    await _channel.invokeMethod(
      'disposeMultiPartyRecorder',
      <String, dynamic>{'recorderId': _recorderId},
    );
    _isReleased = true;
    value = RecorderValue.uninitialized();
  }

  EventChannel _eventChannelFor(int recorderId) {
    return EventChannel('FlutterWebRTC/MultiPartyRecorderEvents/$recorderId');
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

  void errorListener(dynamic obj) {
    final PlatformException e = obj;
    throw e;
  }
}
