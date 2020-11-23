import 'dart:async';

import 'package:flutter_webrtc/src/interface/multi_party_recorder.dart';

import '../interface/factory.dart';
import '../interface/media_recorder.dart';
import '../interface/media_stream.dart';
import '../interface/navigator.dart';
import '../interface/rtc_peerconnection.dart';
import '../interface/rtc_video_renderer.dart';
import 'media_recorder_impl.dart';
import 'media_stream_impl.dart';
import 'multi_party_recorder_impl.dart';
import 'navigator_impl.dart';
import 'rtc_peerconnection_impl.dart';
import 'rtc_video_renderer_impl.dart';
import 'utils.dart';

class RTCFactoryNative extends RTCFactory {
  RTCFactoryNative._internal();

  static final RTCFactory instance = RTCFactoryNative._internal();

  @override
  Future<MediaStream> createLocalMediaStream(String label) async {
    var _channel = WebRTC.methodChannel();

    final response = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('createLocalMediaStream');

    return MediaStreamNative(response['streamId'], label);
  }

  @override
  Future<RTCPeerConnection> createPeerConnection(
      Map<String, dynamic> configuration,
      [Map<String, dynamic> constraints = const {}]) async {
    var channel = WebRTC.methodChannel();

    var defaultConstraints = <String, dynamic>{
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    final response = await channel.invokeMethod<Map<dynamic, dynamic>>(
      'createPeerConnection',
      <String, dynamic>{
        'configuration': configuration,
        'constraints': constraints.isEmpty ? defaultConstraints : constraints
      },
    );

    String peerConnectionId = response['peerConnectionId'];
    return RTCPeerConnectionNative(peerConnectionId, configuration);
  }

  @override
  MediaRecorder mediaRecorder() {
    return MediaRecorderNative();
  }

  @override
  MultiPartyRecorder multiPartyRecorder({
    int fps = 24,
    bool audioOnly = false,
    MediaFormat format = MediaFormat.mpeg4,
    MultiPartyRecorderType type = MultiPartyRecorderType.local,
    videoSize,
  }) {
    return MultiPartyRecorderNative(
      fps: fps,
      audioOnly: audioOnly,
      format: format,
      type: type,
      videoSize: videoSize,
    );
  }

  @override
  VideoRenderer videoRenderer() {
    return RTCVideoRendererNative();
  }

  @override
  Navigator get navigator => NavigatorNative();
}
