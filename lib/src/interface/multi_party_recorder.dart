import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum MediaRecorderType {
  local,
  mixed,
}

enum MediaFormat {
  mpeg4,
  webm,
}

class MediaRecorderMetaData {
  MediaRecorderMetaData(
    this.url, {
    this.thumbnailWidth,
    this.thumbnailHeight,
    this.thumbnailData,
    this.videoWidth,
    this.videoHeight,
    this.duration,
    this.mimeType,
    this.frameRate,
    this.isAudioOnly,
  });

  factory MediaRecorderMetaData.fromMap(Map<String, dynamic> map) {
    return MediaRecorderMetaData(
      map['url'],
      thumbnailWidth: map['thumbnailWidth'],
      thumbnailHeight: map['thumbnailHeight'],
      thumbnailData: map['thumbnailData'],
      videoWidth: map['videoWidth'],
      videoHeight: map['videoHeight'],
      duration: map['duration'],
      mimeType: map['mimeType'],
      frameRate: map['frameRate'],
      isAudioOnly: map['isAudioOnly'],
    );
  }

  int thumbnailWidth;
  int thumbnailHeight;
  int videoWidth;
  int videoHeight;
  double duration;
  Uint8List thumbnailData;
  String mimeType;
  double frameRate;
  bool isAudioOnly;
  String url;

  MediaRecorderMetaData copyWith(
      {int thumbnailWidth,
      int thumbnailHeight,
      int videoWidth,
      int videoHeight,
      int duration,
      Uint8List thumbnailData,
      String mimeType,
      double frameRate,
      bool isAudioOnly,
      String url}) {
    return MediaRecorderMetaData(
      url ?? this.url,
      thumbnailWidth: thumbnailWidth ?? this.thumbnailWidth,
      thumbnailHeight: thumbnailHeight ?? this.thumbnailHeight,
      thumbnailData: thumbnailData ?? this.thumbnailData,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      duration: duration ?? this.duration,
      mimeType: mimeType ?? this.mimeType,
      frameRate: frameRate ?? this.frameRate,
      isAudioOnly: isAudioOnly ?? this.isAudioOnly,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'thumbnailWidth': thumbnailWidth,
      'thumbnailHeight': thumbnailHeight,
      'thumbnailData': thumbnailData,
      'videoWidth': videoWidth,
      'videoHeight': videoHeight,
      'duration': duration,
      'mimeType': mimeType,
      'frameRate': frameRate,
      'isAudioOnly': isAudioOnly,
      'url': url,
    };
  }

  @override
  String toString() {
    return '$runtimeType('
        'thumbnailWidth: $thumbnailWidth, '
        'thumbnailHeight: $thumbnailHeight, '
        //'thumbnailData: $thumbnailData, '
        'videoHeight: $videoHeight, '
        'videoWidth: $videoWidth, '
        'duration: $duration, '
        'mimeType: $mimeType, '
        'frameRate: $frameRate, '
        'url: $url, '
        'isAudioOnly: $isAudioOnly)';
  }
}

class MetaDataOptions {
  const MetaDataOptions(
      {this.thumbnailWidth,
      this.thumbnailHeight,
      this.thumbnailQuality,
      this.isAudioOnly});

  factory MetaDataOptions.fromMap(Map<String, dynamic> map) {
    return MetaDataOptions(
      thumbnailWidth: map['thumbnailWidth'],
      thumbnailHeight: map['thumbnailHeight'],
      thumbnailQuality: map['thumbnailQuality'],
      isAudioOnly: map['isAudioOnly'],
    );
  }
  final int thumbnailWidth;
  final int thumbnailHeight;
  final double thumbnailQuality;
  final bool isAudioOnly;

  MetaDataOptions copyWith({
    int thumbnailWidth,
    int thumbnailHeight,
    double thumbailQuality,
    bool isAudioOnly,
  }) {
    return MetaDataOptions(
      thumbnailWidth: thumbnailWidth ?? this.thumbnailWidth,
      thumbnailHeight: thumbnailHeight ?? this.thumbnailHeight,
      thumbnailQuality: thumbailQuality ?? this.thumbnailQuality,
      isAudioOnly: isAudioOnly ?? this.isAudioOnly,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'thumbnailWidth': thumbnailWidth,
      'thumbnailHeight': thumbnailHeight,
      'thumbnailQuality': thumbnailQuality,
      'isAudioOnly': isAudioOnly,
    };
  }

  @override
  String toString() {
    return '$runtimeType('
        'thumbnailWidth: $thumbnailWidth, '
        'thumbnailHeight: $thumbnailHeight, '
        'isAudioOnly: $isAudioOnly, '
        'thumbnailQuality: $thumbnailQuality, )';
  }
}

/// This is thrown when the plugin reports an error.
class RecorderException implements Exception {
  RecorderException(this.code, this.description);

  String code;
  String description;

  @override
  String toString() => '$runtimeType($code, $description)';
}

/// The state of a [MediaRecorder].
class RecorderValue {
  const RecorderValue({
    this.isInitialized,
    this.isPaused,
    this.errorDescription,
    this.isRecordingVideo,
    this.videoSize,
    this.fps,
  });

  const RecorderValue.uninitialized()
      : this(isInitialized: false, isRecordingVideo: false, isPaused: false);

  /// True after [RecorderValue.initialize] has completed successfully.
  final bool isInitialized;

  /// True after [RecorderValue.pause] has completed successfully.
  final bool isPaused;

  /// True when the camera is recording (not the same as previewing).
  final bool isRecordingVideo;

  final String errorDescription;

  /// The size of the preview in pixels.
  ///
  /// Is `null` until  [isInitialized] is `true`.
  final Size videoSize;

  final int fps;

  bool get hasError => errorDescription != null;

  RecorderValue copyWith({
    bool isInitialized,
    bool isRecordingVideo,
    bool isConnected,
    bool isPaused,
    String errorDescription,
    Size videoSize,
    int fps,
  }) {
    return RecorderValue(
        isInitialized: isInitialized ?? this.isInitialized,
        isPaused: isPaused ?? this.isPaused,
        errorDescription: errorDescription,
        videoSize: videoSize ?? this.videoSize,
        isRecordingVideo: isRecordingVideo ?? this.isRecordingVideo,
        fps: fps ?? this.fps);
  }

  @override
  String toString() {
    return '$runtimeType('
        'isRecordingVideo: $isRecordingVideo, '
        'isPaused: $isPaused, '
        'isInitialized: $isInitialized, '
        'errorDescription: $errorDescription, '
        'videoSize: $videoSize), '
        'fps: $fps)';
  }
}

class VideoTrackObserver {
  VideoTrackObserver(this.recorder, this.track);
  final MediaStreamTrack track;
  final MediaRecorder recorder;
}

abstract class MediaRecorder extends ValueNotifier<RecorderValue> {
  MediaRecorder({
    this.fps = 24,
    this.audioOnly = false,
    this.format = MediaFormat.mpeg4,
    this.type = MediaRecorderType.local,
    this.videoSize,
  })  : assert(type != null),
        assert(fps != null),
        assert(audioOnly != null),
        assert(audioOnly ? videoSize == null : videoSize != null),
        assert(format != null),
        super(const RecorderValue.uninitialized());
  final MediaRecorderType type;
  final MediaFormat format;
  final Size videoSize;
  final int fps;
  final bool audioOnly;
  static String stringFromMediaRecorderType(MediaRecorderType type) {
    switch (type) {
      case MediaRecorderType.local:
        return 'local';
      case MediaRecorderType.mixed:
        return 'mixed';
    }
    throw ArgumentError('Unknown ConnectionType value');
  }

  static String stringFromMediaFormat(MediaFormat mediaFormat) {
    switch (mediaFormat) {
      case MediaFormat.mpeg4:
        return 'mpeg4';
      case MediaFormat.webm:
        return 'webm';
    }
    throw ArgumentError('Unknown ConnectionType value');
  }

  Future<void> addVideoTrack(MediaStreamTrack track);

  Future<void> removeVideoTrack(MediaStreamTrack track);

  Future<void> setPaused(bool paused);

  Future<void> start(String filePath);

  void startWeb(
    MediaStream stream, {
    Function(dynamic blob, bool isLastOne) onDataChunk,
    String mimeType,
  });

  /// Stop recording.
  Future<void> stop();

  Future<void> release();
}
