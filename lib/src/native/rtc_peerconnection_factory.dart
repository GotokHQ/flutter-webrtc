import 'dart:async';

import 'dart:ui';
import 'package:flutter_webrtc/src/interface/multi_party_recorder.dart';

import '../interface/media_recorder.dart';
import '../interface/media_stream.dart';
import '../interface/navigator.dart';
import '../interface/rtc_peerconnection.dart';
import '../interface/rtc_video_renderer.dart';
import 'factory_impl.dart';

Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration,
    [Map<String, dynamic> constraints = const {}]) async {
  return RTCFactoryNative.instance
      .createPeerConnection(configuration, constraints);
}

Future<MediaStream> createLocalMediaStream(String label) async {
  return RTCFactoryNative.instance.createLocalMediaStream(label);
}

MediaRecorder mediaRecorder() {
  return RTCFactoryNative.instance.mediaRecorder();
}

MultiPartyRecorder multiPartyRecorder({
  int fps = 24,
  bool audioOnly = false,
  MediaFormat format = MediaFormat.mpeg4,
  MultiPartyRecorderType type = MultiPartyRecorderType.local,
  Size? videoSize,
}) {
  return RTCFactoryNative.instance.multiPartyRecorder(
      fps: fps,
      audioOnly: audioOnly,
      format: format,
      type: type,
      videoSize: videoSize);
}

VideoRenderer videoRenderer() {
  return RTCFactoryNative.instance.videoRenderer();
}

Navigator get navigator => RTCFactoryNative.instance.navigator;
