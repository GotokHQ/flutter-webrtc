import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'media_stream.dart';

class RTCVideoAppLifeCycleObserver extends Object with WidgetsBindingObserver {
  RTCVideoAppLifeCycleObserver(this._controller);

  final VideoRenderer _controller;

  void initialize() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _controller.muted = true;
        break;
      case AppLifecycleState.resumed:
        _controller.muted = false;
        break;
      default:
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}

@immutable
class RTCVideoValue {
  RTCVideoValue({
    @required this.size,
    this.rotation = 0,
    this.errorDescription,
    this.firstFrameRendered,
    this.isMirrored,
    this.isBlurred = false,
    this.mute = true,
    this.renderVideo = false,
  });

  RTCVideoValue.uninitialized() : this(size: null);

  RTCVideoValue.erroneous(String errorDescription)
      : this(size: null, errorDescription: errorDescription);

  final int rotation;
  final bool firstFrameRendered;
  final bool isMirrored;
  final bool isBlurred;
  final bool mute;
  final String errorDescription;
  final bool renderVideo;

  final Size size;

  bool get initialized => size != null;
  bool get hasError => errorDescription != null;

  double get aspectRatio {
    if (size == null || size.width == 0 || size.height == 0) {
      return 1.0;
    }
    return (rotation == 90 || rotation == 270)
        ? size.height / size.width
        : size.width / size.height;
  }

  @override
  int get hashCode => hashValues(
      rotation, firstFrameRendered, isMirrored, errorDescription, size, mute);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RTCVideoValue &&
          runtimeType == other.runtimeType &&
          hashCode == other.hashCode;

  RTCVideoValue copyWith({
    Size size,
    int rotation,
    bool firstFrameRendered,
    String errorDescription,
    bool isMirrored,
    bool mute,
    bool isBlurred,
    bool renderVideo,
  }) {
    return RTCVideoValue(
      size: size ?? this.size,
      rotation: rotation ?? this.rotation,
      firstFrameRendered: firstFrameRendered ?? this.firstFrameRendered,
      errorDescription: errorDescription ?? this.errorDescription,
      isMirrored: isMirrored ?? this.isMirrored,
      mute: mute ?? this.mute,
      isBlurred: isBlurred ?? this.isBlurred,
      renderVideo: renderVideo ?? this.renderVideo,
    );
  }

  @override
  String toString() {
    return '$runtimeType('
        'size: $size, '
        'rotation: $rotation, '
        'firstFrameRendered: $firstFrameRendered, '
        'isMirrored: $isMirrored, '
        'mute: $mute, '
        'isBlurred: $isBlurred, '
        'renderVideo: $renderVideo, '
        'errorDescription: $errorDescription)';
  }
}

abstract class VideoRenderer extends ValueNotifier<RTCVideoValue> {
  VideoRenderer() : super(RTCVideoValue.uninitialized());

  Function onResize;

  int get videoWidth;

  int get videoHeight;

  bool get muted;
  set muted(bool mute);

  ///Return true if the audioOutput have been succesfully changed
  Future<bool> audioOutput(String deviceId);

  bool get renderVideo;
  int get textureId;

  Future<void> initialize();

  MediaStream get srcObject;
  set srcObject(MediaStream stream);

  bool get blurred;
  set blurred(bool blur);

  @override
  @mustCallSuper
  Future<void> dispose() async {
    super.dispose();
    return Future.value();
  }

  Future<void> release();
}
