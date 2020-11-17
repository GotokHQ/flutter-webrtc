import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;

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
  }

  final html.MediaStreamTrack jsTrack;
  bool _isReleased = false;

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
  Future<void> setVolume(double volume) async {
    final constraints = jsTrack.getConstraints();
    constraints['volume'] = volume;
    js.JsObject.fromBrowserObject(jsTrack)
        .callMethod('applyConstraints', [js.JsObject.jsify(constraints)]);
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
  Future<void> stop() async {}

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
  Future<void> dispose() {
    release();
    super.dispose();
    return null;
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
