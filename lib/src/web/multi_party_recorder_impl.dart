import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as jsutil;
import 'dart:math';
import 'dart:web_audio';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/src/web/media_stream_track_impl.dart';

import '../interface/media_stream.dart';
import '../interface/media_stream_track.dart';
import '../interface/multi_party_recorder.dart';

class VideoMixerSource {
  VideoMixerSource._(this.trackId, this.context2d,
      {this.rectangle = Rect.zero, this.mirror = false});

  //html.OffscreenCanvas? _bitmapCanvas;
  final html.OffscreenCanvasRenderingContext2D context2d;
  final String trackId;
  final bool mirror;
  Rect rectangle;

  Future<void> draw(html.ImageBitmap bitmap) async {
    if (context2d.canvas == null) {
      return;
    }
//     const fitImageToCanvas = (image,canvas) => {
//   const canvasContext = canvas.getContext("2d");
//   const ratio = image.width / image.height;
//   let newWidth = canvas.width;
//   let newHeight = newWidth / ratio;
//   if (newHeight < canvas.height) {
//     newHeight = canvas.height;
//     newWidth = newHeight * ratio;
//   }
//   const xOffset = newWidth > canvas.width ? (canvas.width - newWidth) / 2 : 0;
//   const yOffset =
//     newHeight > canvas.height ? (canvas.height - newHeight) / 2 : 0;
//   canvasContext.drawImage(image, xOffset, yOffset, newWidth, newHeight);
// };
    //_bitmapCanvas ??= html.OffscreenCanvas(bitmap.width!, bitmap.height!);
    // final renderer = _bitmapCanvas.getContext('bitmaprenderer')
    //     as html.ImageBitmapRenderingContext;
    // _bitmapCanvas.width = bitmap.width;
    // _bitmapCanvas.height = bitmap.height;
    // renderer.transferFromImageBitmap(bitmap);
    var hRatio = context2d.canvas!.width! / bitmap.width!;
    var vRatio = context2d.canvas!.height! / bitmap.height!;
    var ratio = max(hRatio, vRatio);
    var centerShift_x =
        rectangle.left + (bitmap.width! - bitmap.width! * ratio) / 2;
    var centerShift_y =
        rectangle.top + (bitmap.height! - bitmap.height! * ratio) / 2;
    //context2d.clearRect(0, 0, rectangle.width, rectangle.height);

    context2d.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height,
        centerShift_x, centerShift_y, rectangle.width, rectangle.height);
  }
}

class VideoMixer {
  VideoMixer(this.canvas);

  final List<VideoMixerSource> videoSources = [];
  final html.OffscreenCanvas canvas;

  void addSource(String trackId) {
    if (videoSources.contains((element) => trackId == element.trackId)) return;
    videoSources.add(VideoMixerSource._(
      trackId,
      canvas.getContext('2d') as html.OffscreenCanvasRenderingContext2D,
    ));
    updateLayout();
  }

  void removeSource(String trackId) {
    if (!videoSources.contains((element) => trackId == element.trackId)) return;

    final videoSource = videoSources.firstWhere(
      (element) => trackId == element.trackId,
    );
    videoSources.remove(videoSource);
    updateLayout();
    //_videoTrackObservers[track.id] = VideoTrackObserver(this, track);
  }

  void updateLayout() {
    if (videoSources.length == 1) {
      videoSources[0].rectangle = Rect.fromLTWH(
          0, 0, canvas.width!.toDouble(), canvas.height!.toDouble());
    } else {
      var width = (canvas.width! / videoSources.length).toDouble();
      var xPos = 0.0;
      var yPos = 0.0;
      videoSources.forEach((element) {
        element.rectangle =
            Rect.fromLTWH(xPos, yPos, width, canvas.height!.toDouble());
        xPos += width;
      });
    }
  }

  void drawFrame(String trackId, html.ImageBitmap frame) {
    final video = videoSources.firstWhere(
      (element) => trackId == element.trackId,
    );
    video.draw(frame);
  }

  void release() {
    videoSources.clear();
  }
}

class _AudioSourceDescription {
  _AudioSourceDescription._(this.track, this.sourceNode);

  final MediaStreamTrackWeb track;
  final AudioNode sourceNode;
}

class _VideoSourceDescription {
  _VideoSourceDescription._(this.track)
      : imageCapture = html.ImageCapture(track.jsTrack);

  final html.ImageCapture imageCapture;
  final MediaStreamTrackWeb track;

  Future<html.ImageBitmap> grabFrame() async {
    final imageCapture = html.ImageCapture(track.jsTrack);
    final bitmap = await imageCapture.grabFrame();
    return bitmap;
  }
}

class MultiPartyRecorderWeb extends MultiPartyRecorder {
  MultiPartyRecorderWeb({
    int? fps,
    bool? audioOnly,
    MediaFormat? format,
    Size? videoSize,
    MultiPartyRecorderType? type,
  }) : super(
            fps: fps,
            audioOnly: audioOnly,
            format: format,
            type: type,
            videoSize: videoSize) {
    _initialize();
  }

  bool running = false;
  bool _isReleased = false;
  List<_VideoSourceDescription> videoSources = [];
  List<_AudioSourceDescription> audioSources = [];
  html.MediaRecorder? _recorder;
  Completer<String>? _completer;
  late AudioContext _audioContext;
  VideoMixer? _videoMixer;
  html.CanvasElement? _canvas;
  late MediaStreamAudioDestinationNode _audioDestinationNode;
  late GainNode _gainNode;

  Future<void> _initialize() async {
    if (videoSize != null) {
      _canvas = html.Element.canvas() as html.CanvasElement;
      _canvas!.width = videoSize!.width.toInt();
      _canvas!.height = videoSize!.height.toInt();
      _videoMixer = VideoMixer(_canvas!.transferControlToOffscreen());
    }
    _audioContext = AudioContext();
    _audioDestinationNode = _audioContext.createMediaStreamDestination();
    _gainNode = _audioContext.createGain();
    _gainNode.connectNode(_audioContext.destination!);
    _gainNode.gain?.value = 0; // don't hear self
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<void> addTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    if (track.kind == 'video') {
      if (videoSources.contains((element) => element.track.id == track.id)) {
        return;
      }
      videoSources.add(_VideoSourceDescription._(track as MediaStreamTrackWeb));
      _videoMixer?.addSource(track.id!);
    } else if (track.kind == 'audio') {
      if (audioSources.contains((element) => element.track.id == track.id)) {
        return;
      }
      final audioSourceDesc = _AudioSourceDescription._(
          track as MediaStreamTrackWeb,
          jsutil.callMethod(
              _audioContext, 'createMediaStreamTrackSource', [track.jsTrack]));
      audioSources.add(
        audioSourceDesc,
      );
      _audioDestinationNode.connectNode(audioSourceDesc.sourceNode);
      audioSourceDesc.sourceNode.connectNode(_gainNode);
    }
  }

  @override
  Future<void> removeTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    if (track.kind == 'video') {
      if (!videoSources.contains((element) => element.track.id == track.id)) {
        return;
      }
      final videoSource = videoSources.firstWhere(
        (element) => element.track.id == track.id,
      );
      videoSources.remove(videoSource);
      _videoMixer?.removeSource(track.id!);
    } else if (track.kind == 'audio') {
      if (!audioSources.contains((element) => element.track.id == track.id)) {
        return;
      }
      final audioSource = audioSources.firstWhere(
        (element) => element.track.id == track.id,
      );
      audioSources.remove(audioSource);
      _audioDestinationNode.disconnect(audioSource);
    }
    //_videoTrackObservers[track.id] = VideoTrackObserver(this, track);
  }

  Future<void> draw(highResTime) async {
    if (!value.isRecordingVideo || value.isPaused) {
      return;
    }
    // canvas.context2D.drawImageScaled(source, destX, destY, destWidth, destHeight)
    final futures = videoSources.map((desc) async {
      final frame = await desc.grabFrame();
      _videoMixer?.drawFrame(desc.track.id!, frame);
    });
    await Future.wait(futures);
    html.window.requestAnimationFrame(draw);
  }

  html.MediaStream getMixedStream() {
    html.MediaStream mediaStream;
    if (_audioDestinationNode.stream == null) {
      mediaStream = html.MediaStream();
    } else {
      mediaStream = html.MediaStream(_audioDestinationNode.stream);
    }
    final videoStream = _canvas?.captureStream(fps);
    if (videoStream != null) {
      videoStream.getTracks().forEach((track) {
        mediaStream.addTrack(track);
      });
    }
    return mediaStream;
  }

  @override
  Future<void> setPaused(bool paused) async {
    print('value.isPaused is ${value.isPaused}');
  }

  @override
  Future<void> start(String filePath) async {}

  @override
  Future<void> startWeb({
    Function(dynamic blob, bool isLastOne)? onDataChunk,
    String? mimeType = 'video/webm',
  }) async {
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MultiPartyRecorder',
        description:
            'startVideoRecording was called on uninitialized MultiPartyRecorder',
      );
    }
    if (value.isRecordingVideo) {
      throw RecorderException(
        'A video recording is already started.',
        description:
            'startVideoRecording was called when a recording is already started.',
      );
    }
    value = value.copyWith(isRecordingVideo: true);

    _recorder = html.MediaRecorder(getMixedStream(), {'mimeType': mimeType});
    if (onDataChunk == null) {
      var _chunks = <html.Blob>[];
      _completer = Completer<String>();
      _recorder?.addEventListener('dataavailable', (html.Event event) {
        final html.Blob blob = js.JsObject.fromBrowserObject(event)['data'];
        if (blob.size > 0) {
          _chunks.add(blob);
        }
        if (_recorder!.state == 'inactive') {
          final blob = html.Blob(_chunks, mimeType);
          _completer?.complete(html.Url.createObjectUrlFromBlob(blob));
          _completer = null;
        }
      });
      _recorder!.onError.listen((error) {
        _completer?.completeError(error);
        _completer = null;
        value = value.copyWith(isRecordingVideo: false);
      });
    } else {
      _recorder!.addEventListener('dataavailable', (html.Event event) {
        onDataChunk(
          js.JsObject.fromBrowserObject(event)['data'],
          _recorder!.state == 'inactive',
        );
      });
    }
    _recorder!.start();
    html.window.requestAnimationFrame(draw);
  }

  /// Stop recording.

  @override
  Future<MultiPartyRecorderMetaData?> stop(
      {returnMetaData = false,
      metaDataOptions = const MetaDataOptions(
          isAudioOnly: false,
          thumbnailHeight: 200,
          thumbnailWidth: 200,
          thumbnailQuality: 0.7)}) async {
    if (!value.isInitialized || _isReleased) {
      throw RecorderException(
        'Uninitialized MultiPartyRecorder',
        description:
            'stopVideoRecording was called on uninitialized MultiPartyRecorder',
      );
    }
    if (!value.isRecordingVideo) {
      throw RecorderException(
        'No video is recording',
        description:
            'stopVideoRecording was called when no video is recording.',
      );
    }
    value = value.copyWith(isRecordingVideo: false);
    _recorder?.stop();
    _recorder = null;
  }

  @override
  bool operator ==(dynamic other) {
    if (identical(this, other)) return true;
    if (runtimeType != other.runtimeType) return false;
    return other.hashCode == hashCode;
  }

  @override
  int get hashCode => videoSize.hashCode;

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
    _isReleased = true;

    value = value.copyWith(isRecordingVideo: false);
    _recorder?.stop();
    _recorder = null;

    _gainNode.disconnect();
    audioSources.forEach((source) {
      source.sourceNode.disconnect();
    });
    audioSources = [];
    _audioDestinationNode.disconnect();
    _audioContext.close();
    _videoMixer?.release();
    _videoMixer = null;
    value = RecorderValue.uninitialized();
  }
}
