import 'dart:async';
import 'package:flutter/material.dart';

typedef StreamTrackCallback = Function();

/// The state of a [MediaStreamTrackValue].
class MediaStreamTrackValue {
  const MediaStreamTrackValue(
      {this.id,
      this.label,
      this.remote,
      this.kind,
      this.enabled,
      this.switched,
      this.switching = false,
      this.running = true,
      this.speakerEnabled = true,
      this.speakerEnabling = false});

  const MediaStreamTrackValue.uninitialized()
      : this(
          id: null,
          label: null,
          remote: false,
          kind: null,
          running: true,
          enabled: false,
          switched: false,
          switching: false,
          speakerEnabled: true,
          speakerEnabling: false,
        );

  final String id;
  final String label;
  final bool remote;
  final String kind;
  final bool enabled;
  final bool switching;
  final bool switched;
  final bool running;
  final bool speakerEnabled;
  final bool speakerEnabling;

  MediaStreamTrackValue copyWith({
    String id,
    String label,
    bool remote,
    String kind,
    bool enabled,
    bool switched,
    bool switching,
    bool running,
    bool speakerEnabled,
    bool speakerEnabling,
  }) {
    return MediaStreamTrackValue(
      id: id ?? this.id,
      label: label ?? this.label,
      remote: remote ?? this.remote,
      kind: label ?? this.kind,
      enabled: enabled ?? this.enabled,
      switched: switched ?? this.switched,
      switching: switching ?? this.switching,
      running: running ?? this.running,
      speakerEnabled: speakerEnabled ?? this.speakerEnabled,
      speakerEnabling: speakerEnabling ?? this.speakerEnabling,
    );
  }

  @override
  String toString() {
    return '$runtimeType('
        'id: $id, '
        'label: $label, '
        'remote: $remote, '
        'kind: $kind, '
        'enabled: $enabled, '
        'switched: $switched, '
        'switching: $switching, '
        'speakerEnabled: $speakerEnabled, '
        'speakerEnabling: $speakerEnabling, '
        'running: $running, ';
  }
}

abstract class MediaStreamTrack extends ValueNotifier<MediaStreamTrackValue> {
  MediaStreamTrack({
    String id,
    String label,
    String kind,
    bool enabled,
    bool remote,
    bool switched,
    bool switching,
    bool running,
  }) : super(MediaStreamTrackValue(
          id: id,
          label: label,
          kind: kind,
          enabled: enabled,
          remote: remote,
          switched: switched,
          switching: switching,
          running: running,
        ));

  String get id => value.id;
  String get label => value.label;
  String get kind => value.kind;
  bool get remote => value.remote;
  bool get enabled => value.enabled;
  bool get switched => value.switched;
  bool get running => value.running;
  bool get switching => value.switching;
  bool get speakerEnabled => value.speakerEnabled;
  bool get speakerEnabling => value.speakerEnabling;
  bool get isVideoTrack => value.kind == 'video';
  bool get isAudioTrack => value.kind == 'audio';

  set enabled(bool enabled);
  Future<void> enableSpeakerphone(bool enable);

  @override
  Future<void> dispose();

  Future<void> release();

  Future<void> switchCamera();

  Future<void> stop();

  Future<void> start();

  Future<void> adaptRes(int width, int height, {int frameRate});

  Future<void> setVolume(double volume);

  Future<void> setMicrophoneMute(bool mute);

  Future<dynamic> captureFrame([String filePath]);

  Future<bool> hasTorch();

  Future<void> setTorch(bool torch);

  Future<bool> restartCamera();
  @override
  bool operator ==(other) =>
      other is MediaStreamTrack && other.hashCode == hashCode;

  @override
  int get hashCode => value.id.hashCode;
}
