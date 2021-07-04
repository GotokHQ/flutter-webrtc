import '../flutter_webrtc.dart';
import 'interface/multi_party_recorder.dart' as _interface;

class MultiPartyRecorder extends _interface.MultiPartyRecorder {
  MultiPartyRecorder({
    int fps = 24,
    bool audioOnly = false,
    _interface.MediaFormat format = _interface.MediaFormat.mpeg4,
    _interface.MultiPartyRecorderType type =
        _interface.MultiPartyRecorderType.local,
    videoSize,
  }) : _delegate = multiPartyRecorder(
            fps: fps,
            audioOnly: audioOnly,
            format: format,
            type: type,
            videoSize: videoSize);
  final _interface.MultiPartyRecorder _delegate;

  @override
  Future<void> addTrack(MediaStreamTrack track) async {
    await _delegate.addTrack(track);
  }

  @override
  Future<void> removeTrack(MediaStreamTrack track) async {
    await _delegate.removeTrack(track);
  }

  @override
  Future<void> setPaused(bool paused) async {
    await _delegate.setPaused(paused);
  }

  @override
  Future<void> start(String filePath) async {
    await _delegate.start(filePath);
  }

  @override
  Future<void> startWeb(
    MediaStream stream, {
    Function(dynamic blob, bool isLastOne)? onDataChunk,
    String? mimeType,
  }) =>
      _delegate.startWeb(
        stream,
        onDataChunk: onDataChunk,
        mimeType: mimeType ?? 'video/webm',
      );

  @override
  Future<void> stop() => _delegate.stop();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Future<void> release() => _delegate.release();
}
