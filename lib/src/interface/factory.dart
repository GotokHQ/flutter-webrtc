import 'media_recorder.dart';
import 'media_stream.dart';
import 'multi_party_recorder.dart';
import 'navigator.dart';
import 'rtc_peerconnection.dart';
import 'rtc_video_renderer.dart';

abstract class RTCFactory {
  Future<RTCPeerConnection> createPeerConnection(
      Map<String, dynamic> configuration,
      [Map<String, dynamic> constraints]);

  Future<MediaStream> createLocalMediaStream(String label);

  Navigator get navigator;

  MediaRecorder mediaRecorder();

  VideoRenderer videoRenderer();

  MultiPartyRecorder multiPartyRecorder({
    int fps = 24,
    bool audioOnly = false,
    MediaFormat format = MediaFormat.mpeg4,
    MultiPartyRecorderType type = MultiPartyRecorderType.local,
    videoSize,
  });
}
