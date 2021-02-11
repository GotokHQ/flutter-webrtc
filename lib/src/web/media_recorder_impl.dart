import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as jsutil;
import 'dart:ui';

import 'package:platform_detect/platform_detect.dart';

import '../interface/media_recorder.dart';
import '../interface/media_stream.dart';
import '../interface/media_stream_track.dart';
import 'media_stream_impl.dart';
import 'media_stream_track_impl.dart';

class MediaRecorderWeb extends MediaRecorder {
  html.MediaRecorder _recorder;
  Completer<String> _completer;
  html.CanvasElement _canvas;
  MediaStreamTrackWeb _videoTrack;
  bool _started = false;
  html.VideoElement _videoElement;
  StreamSubscription _sub;
  bool _isImageCaptureSupported = false;

  Future<html.ImageBitmap> grabFrame() async {
    final imageCapture = html.ImageCapture(_videoTrack.jsTrack);
    final bitmap = await imageCapture.grabFrame();
    return bitmap;
  }

  Future<void> draw(highResTime) async {
    if (!_started) {
      return;
    }
    var bitmap;
    num width;
    num height;
    if (_videoElement != null) {
      bitmap = _videoElement;
      width = _videoElement.videoWidth;
      height = _videoElement.videoHeight;
    } else {
      if (_videoTrack.jsTrack.readyState != 'live' || !(_videoTrack.jsTrack.readyState.enabled ?? false) || (_videoTrack.jsTrack.readyState.muted ?? false)) {
        return;
      }
      final imageBitmap = await grabFrame();
      width = imageBitmap.width;
      height = imageBitmap.height;
      bitmap = imageBitmap;
    }
    _canvas.width = width;
    _canvas.height = height;
    _canvas.context2D.clearRect(0, 0, width, height);
    _canvas.context2D.save();
    _canvas.context2D.translate(width, 0);
    _canvas.context2D.scale(-1, 1);
    jsutil.callMethod(_canvas.context2D, 'drawImage', [bitmap, 0, 0]);
    _canvas.context2D.setTransform(1, 0, 0, 1, 0, 0);
    _canvas.context2D.restore();
    html.window.requestAnimationFrame(draw);
    if (bitmap is html.ImageBitmap) {
      bitmap.close();
    }
  }

  html.MediaStream _setUpCanvas(html.MediaStream stream) {
    _canvas = html.Element.canvas();
    if (!_isImageCaptureSupported) {
      _videoElement = html.VideoElement()
        ..muted = true
        ..autoplay = true
        ..style.transform = 'rotateY(180deg)'
        ..srcObject = stream;
      _videoElement.setAttribute('playsinline', '');
      _videoElement.play();
    }
    final captureStream = _canvas.captureStream();
    stream.getAudioTracks().forEach((track) {
      captureStream.addTrack(track);
    });
    return captureStream;
  }

  @override
  Future<void> start(String path,
      {MediaStreamTrack videoTrack,
      MediaStreamTrack audioTrack,
      bool audioOnly = false,
      int rotation,
      Size videoSize}) {
    throw 'Use startWeb on Flutter Web!';
  }

  @override
  void startWeb(
    MediaStream stream, {
    Function(dynamic blob, bool isLastOne) onDataChunk,
    String mimeType = 'video/webm',
    bool mirror = true,
  }) {
    var _native = stream as MediaStreamWeb;
    var videoTracks = _native.getVideoTracks();
    if (videoTracks != null && videoTracks.isNotEmpty) {
      _videoTrack = videoTracks.first;
    }
    var mediaStream = _native.jsStream;
    _isImageCaptureSupported = checkIsImageCaptureSupported();
    if (_videoTrack != null) {
      if (mirror) {
        var captureStream = _setUpCanvas(mediaStream);
        mediaStream = captureStream;
      }
    }
    _recorder = html.MediaRecorder(mediaStream, {'mimeType': mimeType});
    if (onDataChunk == null) {
      var _chunks = <html.Blob>[];
      _completer = Completer<String>();
      _recorder.addEventListener('dataavailable', (html.Event event) {
        final html.Blob blob = js.JsObject.fromBrowserObject(event)['data'];
        if (blob.size > 0) {
          _chunks.add(blob);
        }
        if (_recorder.state == 'inactive') {
          final blob = html.Blob(_chunks, mimeType);
          _completer?.complete(html.Url.createObjectUrlFromBlob(blob));
          _completer = null;
          _started = false;
        }
      });
      _recorder.onError.listen((error) {
        _completer?.completeError(error);
        _completer = null;
        _started = false;
      });
    } else {
      _recorder.addEventListener('dataavailable', (html.Event event) {
        onDataChunk(
          js.JsObject.fromBrowserObject(event)['data'],
          _recorder.state == 'inactive',
        );
      });
    }
    _started = true;
    if (_videoElement != null) {
      _sub = _videoElement.onPlaying.listen(
        (dynamic _) {
          html.window.requestAnimationFrame(draw);
          _recorder.start();
        },
      );
    } else {
      if (_canvas != null) {
        html.window.requestAnimationFrame(draw);
      }
      _recorder.start();
    }
  }

  @override
  Future<dynamic> stop() {
     _started = false;
    _recorder?.stop();
    _sub?.cancel();
    _videoElement?.removeAttribute('src');
    _videoElement?.load();
    _videoElement = null;
    return _completer?.future ?? Future.value();
  }

  static bool isMirrorSupported() {
    return !(browser.isSafari || browser.isWKWebView);
  }

  bool checkIsImageCaptureSupported() {
    try {
      html.ImageCapture(_videoTrack.jsTrack);
      return true;
    } catch (error) {
      //print('error:ImageCapture: $error');
    }
    return false;
  }

  static bool isMediaRecorderSupportedOnWeb(html.MediaStream mediaStream,
      {String mimeType = 'video/webm'}) {
    try {
      html.MediaRecorder(mediaStream, {'mimeType': mimeType});
      return true;
    } catch (error) {
      //print('error:MediaRecorder: $error');
    }
    return false;
  }

  @override
  bool canStartWeb(MediaStream mediaStream, {String mimeType = 'video/webm'}) {
    try {
      html.MediaRecorder(
          (mediaStream as MediaStreamWeb).jsStream, {'mimeType': mimeType});
      return true;
    } catch (error) {
      //print('error:MediaRecorder: $error');
    }
    return false;
  }
}
