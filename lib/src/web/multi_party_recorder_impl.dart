import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/src/web/media_stream_track_impl.dart';

import '../interface/enums.dart';
import '../interface/multi_party_recorder.dart';
import '../interface/media_stream.dart';
import '../interface/media_stream_track.dart';
import 'media_stream_impl.dart';

class _VideoDescription {
  _VideoDescription._(this.track, this.context2d);
  final html.CanvasRenderingContext2D context2d;
  final MediaStreamTrackWeb track;
  html.VideoElement _videoElement;
  html.MediaStream _mediaStream;
  Rect rectangle;

  html.VideoElement get videoElement => _videoElement;
  html.MediaStream get mediaStream => _mediaStream;

  void initialize() {
    _mediaStream = html.MediaStream(track.jsTrack);
    final videoElement = html.VideoElement();
    videoElement.style.objectFit = 'cover';
    videoElement.src = _mediaStream.id;
    videoElement.autoplay = true;
    videoElement.controls = false; // contain or cover
    videoElement.style.border = 'none';
  }

  void draw() {
    var canvas = context2d.canvas ;
   var hRatio = canvas.width  / videoElement.width    ;
   var vRatio =  canvas.height / videoElement.height  ;
   var ratio  = max( hRatio, vRatio );
   var centerShift_x = ( canvas.width - videoElement.width*ratio ) / 2;
   var centerShift_y = ( canvas.height - videoElement.height*ratio ) / 2;  
   context2d.clearRect(rectangle.left,  rectangle.top, rectangle.width, rectangle.height);
  //  ctx.drawImage(img, 0,0, img.width, img.height,
  //                     centerShift_x,centerShift_y,img.width*ratio, img.height*ratio);
  //   context2d.drawImageScaled(source, destX, destY, destWidth, destHeight)

  }

  void dispose() {
    videoElement.removeAttribute('src');
  }
}

class MultiPartyRecorderWeb extends MultiPartyRecorder {
  MultiPartyRecorderWeb({
    int fps,
    bool audioOnly,
    MediaFormat format,
    Size videoSize,
  }) : super(
            fps: fps,
            audioOnly: audioOnly,
            format: format,
            videoSize: videoSize) {
    value = value.copyWith(isInitialized: true);
    canvas.width = videoSize.width.toInt();
    canvas.height = videoSize.height.toInt();
  }

  final html.CanvasElement canvas = html.Element.canvas();
  bool running = false;
  bool _isReleased = false;
  StreamSubscription<dynamic> _eventSubscription;
  Completer<void> _creatingCompleter;
  List<_VideoDescription> videoDescriptions = [];
  List<MediaStreamTrack> audioTracks = [];
  html.MediaRecorder _recorder;
  Completer<String> _completer;

  @override
  Future<void> addVideoTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    if (track.kind == 'video') {
      final video = videoDescriptions.firstWhere(
          (element) => element.track.id == track.id,
          orElse: () => null);
      if (video != null) {
        return;
      }
      
      videoDescriptions.add(_VideoDescription._(track, canvas.context2D));
      if (videoDescriptions.length  == 1) {
        videoDescriptions[0].rectangle = Rect.fromLTWH(0, 0, videoSize.width, videoSize.height);
      } else {
            var width = videoSize.width/videoDescriptions.length;
            var xPos = 0.0;
            var yPos = 0.0;
            videoDescriptions.forEach((element) {
              element.rectangle = Rect.fromLTWH(xPos, yPos, width, videoSize.height);
              xPos += width;
            });
      }
    } else if (track.kind == 'audio') {
      audioTracks.add(track);
    }
  }

  @override
  Future<void> removeVideoTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    try {
      if (track.kind == 'video') {
        videoDescriptions.removeWhere((element) => element.track.id == track.id);
      } else if (track.kind == 'audio') {
        audioTracks.removeWhere((element) => element.id == track.id);
      }
      _videoTrackObservers[track.id] = VideoTrackObserver(this, track);
      //relayout
    } on PlatformException catch (e) {
      throw RecorderException(e.code, e.message);
    }
  }

  void draw() {
    canvas.context2D.drawImageScaled(source, destX, destY, destWidth, destHeight)
 
  }

  @override
  Future<void> setPaused(bool paused) async {
    print('value.isPaused is ${value.isPaused}');
  }

  @override
  Future<void> start(String filePath) async {}

  @override
  Future<void> startWeb(
    MediaStream stream, {
    Function(dynamic blob, bool isLastOne) onDataChunk,
  }) async {
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MultiPartyRecorder',
        'startVideoRecording was called on uninitialized MultiPartyRecorder',
      );
    }
    if (value.isRecordingVideo) {
      throw RecorderException(
        'A video recording is already started.',
        'startVideoRecording was called when a recording is already started.',
      );
    }
    value = value.copyWith(isRecordingVideo: true);

    ;
    _recorder?.start();
  }

  /// Stop recording.

  @override
  Future<MultiPartyRecorderMetaData> stop() async {
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MultiPartyRecorder',
        'stopVideoRecording was called on uninitialized MultiPartyRecorder',
      );
    }
    if (!value.isRecordingVideo) {
      throw RecorderException(
        'No video is recording',
        'stopVideoRecording was called when no video is recording.',
      );
    }
    value = value.copyWith(isRecordingVideo: false);

    _recorder?.stop();
  }

  @override
  bool operator ==(dynamic other) {
    if (identical(this, other)) return true;
    if (runtimeType != other.runtimeType) return false;
    return other.hashCode == hashCode;
  }

  @override
  int get hashCode => _recorderId.hashCode ^ videoSize.hashCode;

  @override
  Future<void> dispose() async {
    await release();
    super.dispose();
  }

  @override
  Future<void> release() async {
    if (_isReleased) {
      return;
    }
    if (_creatingCompleter != null) {
      await _creatingCompleter.future;
      await _eventSubscription?.cancel();
      await _channel.invokeMethod(
        'disposeMultiPartyRecorder',
        <String, dynamic>{'recorderId': _recorderId},
      );
    }
    _isReleased = true;
    value = RecorderValue.uninitialized();
  }
}

class MultiPartyRecorderWeb extends MultiPartyRecorder {
  html.MultiPartyRecorder _recorder;
  final html.MediaStream _jsStream;
  Completer<String> _completer;

  @override
  Future<void> start(
    String path, {
    MediaStreamTrack videoTrack,
    MediaStreamTrack audioTrack,
    RecorderAudioChannel audioChannel,
    int rotation,
  }) {
    throw 'Use startWeb on Flutter Web!';
  }

  @override
  void startWeb(
    MediaStream stream, {
    Function(dynamic blob, bool isLastOne) onDataChunk,
    String mimeType = 'video/webm',
  }) {
    var _native = stream as MediaStreamWeb;
    _recorder = html.MultiPartyRecorder(_native.jsStream, {'mimeType': mimeType});
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
        }
      });
      _recorder.onError.listen((error) {
        _completer?.completeError(error);
        _completer = null;
      });
    } else {
      _recorder.addEventListener('dataavailable', (html.Event event) {
        onDataChunk(
          js.JsObject.fromBrowserObject(event)['data'],
          _recorder.state == 'inactive',
        );
      });
    }
    _recorder.start();
  }

  @override
  Future<dynamic> stop() {
    _recorder?.stop();
    return _completer?.future ?? Future.value();
  }
}
