import 'dart:async';

import '../interface/media_recorder.dart';
import '../interface/media_stream.dart';
import '../interface/multi_party_recorder.dart';
import '../interface/navigator.dart';
import '../interface/rtc_peerconnection.dart';
import '../interface/rtc_video_renderer.dart';
import 'factory_impl.dart';

Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration,
    [Map<String, dynamic>? constraints]) {
  return RTCFactoryWeb.instance
      .createPeerConnection(configuration, constraints);
}

Future<MediaStream> createLocalMediaStream(String label) {
  return RTCFactoryWeb.instance.createLocalMediaStream(label);
}

MediaRecorder mediaRecorder() {
  return RTCFactoryWeb.instance.mediaRecorder();
}

MultiPartyRecorder multiPartyRecorder({
  int fps = 24,
  bool audioOnly = false,
  MediaFormat format = MediaFormat.mpeg4,
  MultiPartyRecorderType type = MultiPartyRecorderType.local,
  videoSize,
}) {
  return RTCFactoryWeb.instance.multiPartyRecorder(
      fps: fps,
      audioOnly: audioOnly,
      format: format,
      type: type,
      videoSize: videoSize);
}

VideoRenderer videoRenderer() {
  return RTCFactoryWeb.instance.videoRenderer();
}

Navigator get navigator => RTCFactoryWeb.instance.navigator;
