import 'dart:async';

import 'package:flutter/services.dart';

import '../interface/media_stream_track.dart';
import 'utils.dart';

class MediaStreamTrackNative extends MediaStreamTrack {
  MediaStreamTrackNative(
      String id, String label, String kind, bool enabled, bool remote)
      : super(
          id: id,
          label: label,
          kind: kind,
          enabled: enabled,
          remote: remote,
          switched: false,
          switching: false,
          running: true,
        );

  factory MediaStreamTrackNative.fromMap(Map<String, dynamic> map) {
    return MediaStreamTrackNative(
      map['id'],
      map['label'],
      map['kind'],
      map['enabled'],
      map['remote'],
    );
  }

  final MethodChannel _channel = WebRTC.methodChannel();
  bool _isReleased = false;

  @override
  set enabled(bool enabled) {
    var old = value.enabled;
    try {
      _channel.invokeMethod('mediaStreamTrackSetEnable',
          <String, dynamic>{'trackId': value.id, 'enabled': enabled});
      value = value.copyWith(enabled: enabled);
    } catch (error) {
      value = value.copyWith(enabled: old);
    }
  }

  @override
  Future<void> switchCamera() async {
    var switched = value.switched;
    try {
      value = value.copyWith(switching: true);
      await _channel.invokeMethod(
        'mediaStreamTrackSwitchCamera',
        <String, dynamic>{'trackId': value.id},
      );
      value = value.copyWith(switched: !switched, switching: false);
    } catch (error) {
      value = value.copyWith(switched: switched, switching: false);
    }
  }

  @override
  Future<bool> restartCamera() => _channel.invokeMethod(
        'mediaStreamTrackRestartCamera',
        <String, dynamic>{'trackId': value.id},
      );

  @override
  Future<bool> hasTorch() => _channel.invokeMethod(
        'mediaStreamTrackHasTorch',
        <String, dynamic>{'trackId': value.id},
      );

  @override
  Future<void> setTorch(bool torch) => _channel.invokeMethod(
        'mediaStreamTrackSetTorch',
        <String, dynamic>{'trackId': value.id, 'torch': torch},
      );

  @override
  void setVolume(double volume) async {
    await _channel.invokeMethod(
      'setVolume',
      <String, dynamic>{'trackId': value.id, 'volume': volume},
    );
  }

  @override
  Future<void> stop() async {
    if (_isReleased) {
      return;
    }
    var running = value.running;
    if (!running) {
      return;
    }
    try {
      value = value.copyWith(running: false);
      await _channel.invokeMethod(
        'mediaStreamTrackStop',
        <String, dynamic>{'trackId': value.id},
      );
    } catch (error) {
      value = value.copyWith(running: running);
    }
  }

  @override
  Future<void> start() async {
    if (_isReleased) {
      return;
    }
    var running = value.running;
    if (running) {
      return;
    }
    try {
      value = value.copyWith(running: true);
      await _channel.invokeMethod(
        'mediaStreamTrackStart',
        <String, dynamic>{'trackId': value.id},
      );
    } catch (error) {
      value = value.copyWith(running: running);
    }
  }

  @override
  Future<void> adaptRes(int width, int height, {int frameRate}) async {
    if (_isReleased) {
      return;
    }
    await _channel.invokeMethod(
      'mediaStreamTrackAdaptOutputFormat',
      <String, dynamic>{
        'trackId': value.id,
        'width': width,
        'height': height,
        'frameRate': frameRate
      },
    );
  }

  @override
  Future<void> setMicrophoneMute(bool mute) async {
    print('MediaStreamTrack:setMicrophoneMute $mute');
    await _channel.invokeMethod(
      'setMicrophoneMute',
      <String, dynamic>{'trackId': value.id, 'mute': mute},
    );
  }

  @override
  Future<void> enableSpeakerphone(bool enable) async {
    var old = value.enabled;
    try {
      value = value.copyWith(speakerEnabling: true);
      await _channel.invokeMethod(
        'enableSpeakerphone',
        <String, dynamic>{'trackId': value.id, 'enable': enable},
      );
      value = value.copyWith(speakerEnabled: enable, speakerEnabling: false);
    } catch (error) {
      value = value.copyWith(speakerEnabled: old, speakerEnabling: false);
    }
  }

  @override
  Future<dynamic> captureFrame([String filePath]) {
    return _channel.invokeMethod<void>(
      'captureFrame',
      <String, dynamic>{'trackId': value.id, 'path': filePath},
    );
  }

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
    _isReleased = true;
    await _channel.invokeMethod(
      'trackDispose',
      <String, dynamic>{'trackId': value.id},
    );
    value = MediaStreamTrackValue.uninitialized();
  }

  Map<String, dynamic> toMap() {
    return {
      'id': value?.id,
      'label': value?.label,
      'kind': value?.kind,
      'enabled': value?.enabled,
      'remote': value?.remote,
      'switched': value?.switched,
    };
  }

  @override
  bool operator ==(other) =>
      other is MediaStreamTrack && other.hashCode == hashCode;

  @override
  int get hashCode => value.id.hashCode;
}
