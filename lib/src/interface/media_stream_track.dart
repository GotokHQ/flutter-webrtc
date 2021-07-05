import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/src/helper.dart';

typedef StreamTrackCallback = Function();

/// The state of a [MediaStreamTrackValue].
class MediaStreamTrackValue {
  const MediaStreamTrackValue(
      {this.id,
      this.label,
      this.remote = false,
      this.kind,
      this.enabled = true,
      this.switched = false,
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

  final String? id;
  final String? label;
  final bool remote;
  final String? kind;
  final bool enabled;
  final bool switching;
  final bool switched;
  final bool running;
  final bool speakerEnabled;
  final bool speakerEnabling;

  MediaStreamTrackValue copyWith({
    String? id,
    String? label,
    bool? remote,
    String? kind,
    bool? enabled,
    bool? switched,
    bool? switching,
    bool? running,
    bool? speakerEnabled,
    bool? speakerEnabling,
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
    String? id,
    String? label,
    String? kind,
    required bool enabled,
    required bool remote,
    required bool switched,
    required bool switching,
    required bool running,
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

  String? get id => value.id!;
  String? get label => value.label!;
  String? get kind => value.kind!;
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

  @override
  Future<void> dispose();

  Future<void> release();

  Future<void> start();

  /// Returns true if the track is muted, and false otherwise.
  bool? get muted;

  /// Returns a map containing the set of constraints most recently established
  /// for the track using a prior call to applyConstraints().
  ///
  /// These constraints indicate values and ranges of values that the Web site
  /// or application has specified are required or acceptable for the included
  /// constrainable properties.
  Map<String, dynamic> getConstraints() {
    throw UnimplementedError();
  }

  /// Applies a set of constraints to the track.
  ///
  /// These constraints let the Web site or app establish ideal values and
  /// acceptable ranges of values for the constrainable properties of the track,
  /// such as frame rate, dimensions, echo cancelation, and so forth.
  Future<void> applyConstraints([Map<String, dynamic>? constraints]) {
    throw UnimplementedError();
  }

  // TODO(wermathurin): This ticket is related to the implementation of jsTrack.getCapabilities(),
  //  https://github.com/dart-lang/sdk/issues/44319.
  //
  // MediaTrackCapabilities getCapabilities() {
  //   throw UnimplementedError();
  // }

  // MediaStreamTrack clone();

  Future<void> stop();

  /// Throws error if switching camera failed
  @Deprecated('use Helper.switchCamera() instead')
  Future<bool> switchCamera() {
    throw UnimplementedError();
  }

  @deprecated
  Future<void> adaptRes(int width, int height, {int? frameRate}) {
    throw UnimplementedError();
  }

  void setVolume(double volume) {
    Helper.setVolume(volume, this);
  }

  void setMicrophoneMute(bool mute) {
    Helper.setMicrophoneMute(mute, this);
  }

  void enableSpeakerphone(bool enable) {
    throw UnimplementedError();
  }

  Future<dynamic> captureFrame() {
    throw UnimplementedError();
  }

  Future<bool?> hasTorch() {
    throw UnimplementedError();
  }

  Future<void> setTorch(bool torch) {
    throw UnimplementedError();
  }

  Future<bool?> restartCamera();

  @override
  bool operator ==(other) =>
      other is MediaStreamTrack && other.hashCode == hashCode;

  @override
  int get hashCode => value.id.hashCode;

  @override
  String toString() {
    return 'Track(id: $id, kind: $kind, label: $label, enabled: $enabled, muted: $muted)';
  }
}
