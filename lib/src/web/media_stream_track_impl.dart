import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js;

import 'package:flutter/foundation.dart';

import '../interface/media_stream_track.dart';

class MediaStreamTrackWeb extends MediaStreamTrack {
  MediaStreamTrackWeb(this.jsTrack, {bool remote})
      : super(
          id: jsTrack.id,
          label: jsTrack.label,
          kind: jsTrack.kind,
          enabled: jsTrack.enabled,
          remote: remote,
          switched: false,
          switching: false,
          running: true,
        ) {
    jsTrack.onEnded.listen((event) {
      value = value.copyWith(running: false);
    });
    jsTrack.onMute.listen((event) {
      value = value.copyWith(enabled: false);
    });
    jsTrack.onUnmute.listen((event) {
      value = value.copyWith(enabled: true);
    });
  }

  bool _isReleased = false;

  final html.MediaStreamTrack jsTrack;

  @override
  String get id => jsTrack.id;

  @override
  String get kind => jsTrack.kind;

  @override
  bool get muted => jsTrack.muted;

  @override
  set enabled(bool enabled) {
    var old = value.enabled;
    try {
      jsTrack.enabled = enabled;
      value = value.copyWith(enabled: enabled);
    } catch (error) {
      value = value.copyWith(enabled: old);
    }
  }

  @override
  Future<bool> switchCamera() async {
    // TODO(cloudwebrtc): ???
    return false;
  }

  @override
  Future<void> adaptRes(int width, int height, {int frameRate}) async {
    // TODO(cloudwebrtc): ???
  }

  @override
  Map<String, dynamic> getConstraints() {
    return jsTrack.getConstraints();
  }

  @override
  Future<void> applyConstraints([Map<String, dynamic> constraints]) async {
    // TODO(wermathurin): Wait for: https://github.com/dart-lang/sdk/commit/1a861435579a37c297f3be0cf69735d5b492bc6c
    // to be merged to use jsTrack.applyConstraints() directly
    final arg = js.jsify(constraints);

    final _val = await js.promiseToFuture<void>(
        js.callMethod(jsTrack, 'applyConstraints', [arg]));
    return _val;
  }

  @override
  Future<void> setMicrophoneMute(bool mute) async {
    jsTrack.enabled = !mute;
  }

  @override
  Future<void> enableSpeakerphone(bool enable) async {
    // var old = value.enabled;
    // try {
    //   value = value.copyWith(speakerEnabling: true);
    //   value = value.copyWith(speakerEnabled: enable, speakerEnabling: false);
    // } catch (error) {
    //   value = value.copyWith(speakerEnabled: old, speakerEnabling: false);
    // }
  }

  @override
  Future<void> stop() async {
    jsTrack.stop();
  }

  @override
  Future<void> start() async {}

  @override
  Future<bool> restartCamera() async {
    return SynchronousFuture(false);
  }

  @override
  Future<void> release() async {
    if (_isReleased) {
      return;
    }
    jsTrack.stop();
    _isReleased = true;
    value = MediaStreamTrackValue.uninitialized();
  }

  @override
  Future<dynamic> captureFrame([String filePath]) async {
    final imageCapture = html.ImageCapture(jsTrack);
    final bitmap = await imageCapture.grabFrame();
    final html.CanvasElement canvas = html.Element.canvas();
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    final html.ImageBitmapRenderingContext renderer =
        canvas.getContext('bitmaprenderer');
    renderer.transferFromImageBitmap(bitmap);
    final dataUrl = canvas.toDataUrl();
    bitmap.close();
    return dataUrl;
  }

  @override
  Future<void> dispose() async {
    await release();
    super.dispose();
  }

  @override
  Future<bool> hasTorch() {
    return Future.value(false);
  }

  @override
  Future<void> setTorch(bool torch) {
    throw UnimplementedError('The web implementation does not support torch');
  }
}
