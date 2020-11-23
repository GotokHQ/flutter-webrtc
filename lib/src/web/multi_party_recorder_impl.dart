import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:math';
import 'package:platform_detect/platform_detect.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/src/web/media_stream_track_impl.dart';
import 'package:dart_web_audio/dart_web_audio.dart';

import '../interface/multi_party_recorder.dart';

class VideoMixerSource {
  VideoMixerSource._(this.trackId, this.context2d, {this.rectangle = Rect.zero})
      : assert(rectangle != null);

  html.OffscreenCanvas _bitmapCanvas;
  final html.OffscreenCanvasRenderingContext2D context2d;
  final String trackId;
  Rect rectangle;

  Future<void> draw(html.ImageBitmap bitmap) async {
    _bitmapCanvas ??= html.OffscreenCanvas(bitmap.width, bitmap.height);
    final renderer = _bitmapCanvas.getContext('bitmaprenderer')
        as html.ImageBitmapRenderingContext;
    _bitmapCanvas.width = bitmap.width;
    _bitmapCanvas.height = bitmap.height;
    renderer.transferFromImageBitmap(bitmap);

    var hRatio = context2d.canvas.width / context2d.canvas.width;
    var vRatio = context2d.canvas.height / context2d.canvas.height;
    var ratio = max(hRatio, vRatio);
    var centerShift_x = rectangle.left +
        (_bitmapCanvas.width - _bitmapCanvas.width * ratio) / 2;
    var centerShift_y = rectangle.top +
        (_bitmapCanvas.height - _bitmapCanvas.height * ratio) / 2;
    //context2d.clearRect(0, 0, rectangle.width, rectangle.height);
    context2d.drawImage(
        _bitmapCanvas,
        0,
        0,
        _bitmapCanvas.width,
        _bitmapCanvas.height,
        centerShift_x,
        centerShift_y,
        rectangle.width,
        rectangle.height);
  }
}

class VideoMixer {
  VideoMixer(this.canvas);

  final List<VideoMixerSource> videoSources = [];
  final html.OffscreenCanvas canvas;

  void addSource(String trackId) {
    final video = videoSources.firstWhere(
        (element) => trackId == element.trackId,
        orElse: () => null);
    if (video != null) {
      return;
    }
    videoSources.add(VideoMixerSource._(
      trackId,
      canvas.getContext('2d'),
    ));
    updateLayout();
  }

  void removeSource(String trackId) {
    final videoSource = videoSources.firstWhere(
        (element) => trackId == element.trackId,
        orElse: () => null);
    if (videoSource != null) {
      videoSources.remove(videoSource);
    }
    updateLayout();
    //_videoTrackObservers[track.id] = VideoTrackObserver(this, track);
  }

  void updateLayout() {
    if (videoSources.length == 1) {
      videoSources[0].rectangle = Rect.fromLTWH(
          0, 0, canvas.width.toDouble(), canvas.height.toDouble());
    } else {
      var width = (canvas.width / videoSources.length).toDouble();
      var xPos = 0.0;
      var yPos = 0.0;
      videoSources.forEach((element) {
        element.rectangle =
            Rect.fromLTWH(xPos, yPos, width, canvas.height.toDouble());
        xPos += width;
      });
    }
  }

  void drawFrame(String trackId, html.ImageBitmap frame) {
    final video = videoSources.firstWhere(
        (element) => trackId == element.trackId,
        orElse: () => null);
    if (video == null) {
      return;
    }
    video.draw(frame);
  }

  void release() {
    videoSources.clear();
  }
}

class _AudioSourceDescription {
  _AudioSourceDescription._(this.track, this.sourceNode);

  final MediaStreamTrackWeb track;
  final MediaStreamTrackAudioSourceNode sourceNode;
}

class _VideoSourceDescription {
  _VideoSourceDescription._(this.track)
      : imageCapture =
            html.ImageCapture(track.jsTrack as html.MediaStreamTrack);

  final html.ImageCapture imageCapture;
  final MediaStreamTrackWeb track;

  Future<html.ImageBitmap> grabFrame() async {
    final imageCapture =
        html.ImageCapture(track.jsTrack as html.MediaStreamTrack);
    final bitmap = await imageCapture.grabFrame();
    return bitmap;
  }
}

class MultiPartyRecorderWeb extends MultiPartyRecorder {
  MultiPartyRecorderWeb({
    int fps,
    bool audioOnly,
    MediaFormat format,
    Size videoSize,
    MultiPartyRecorderType type,
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
  html.MediaRecorder _recorder;
  Completer<String> _completer;
  AudioContext _audioContext;
  VideoMixer _videoMixer;
  html.CanvasElement _canvas;
  MediaStreamAudioDestinationNode _audioDestinationNode;
  GainNode _gainNode;

  Future<void> _initialize() async {
    if (videoSize != null) {
      _canvas = html.Element.canvas();
      _canvas.width = videoSize.width.toInt();
      _canvas.height = videoSize.height.toInt();
      _videoMixer = VideoMixer(_canvas.transferControlToOffscreen());
    }
    _audioContext = AudioContext(AudioContextOptions(sampleRate: 48000));
    _audioDestinationNode = _audioContext.createMediaStreamDestination();
    _gainNode = _audioContext.createGain();
    _gainNode.connect(_audioContext.destination);
    _gainNode.gain.value = 0; // don't hear self
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<void> addTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    if (track.kind == 'video') {
      final video = videoSources.firstWhere(
          (element) => element.track.id == track.id,
          orElse: () => null);
      if (video != null) {
        return;
      }
      videoSources.add(_VideoSourceDescription._(track));
      _videoMixer?.addSource(track.id);
    } else if (track.kind == 'audio') {
      final audioSource = audioSources.firstWhere(
          (element) => element.track.id == track.id,
          orElse: () => null);
      if (audioSource != null) {
        return;
      }
      final audioSourceDesc = _AudioSourceDescription._(
        track,
        _audioContext.createMediaStreamTrackSource(
            (track as MediaStreamTrackWeb).jsTrack),
      );
      audioSources.add(
        audioSourceDesc,
      );
      _audioDestinationNode.connect(audioSourceDesc.sourceNode);
      audioSourceDesc.sourceNode.connect(_gainNode);
    }
  }

  @override
  Future<void> removeTrack(MediaStreamTrack track) async {
    if (!value.isInitialized || _isReleased) {
      return;
    }
    if (track.kind == 'video') {
      final videoSource = videoSources.firstWhere(
          (element) => element.track.id == track.id,
          orElse: () => null);
      if (videoSource != null) {
        videoSources.remove(videoSource);
      }
      _videoMixer?.removeSource(track.id);
    } else if (track.kind == 'audio') {
      final audioSource = audioSources.firstWhere(
          (element) => element.track.id == track.id,
          orElse: () => null);
      if (audioSource != null) {
        audioSources.remove(audioSource);
        _audioDestinationNode.disconnect(audioSource);
      }
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
      _videoMixer.drawFrame(desc.track.id, frame);
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

    _recorder = html.MediaRecorder(getMixedStream(), {'mimeType': mediaFormat});
    if (onDataChunk == null) {
      var _chunks = <html.Blob>[];
      _completer = Completer<String>();
      _recorder.addEventListener('dataavailable', (html.Event event) {
        final html.Blob blob = js.JsObject.fromBrowserObject(event)['data'];
        if (blob.size > 0) {
          _chunks.add(blob);
        }
        if (_recorder.state == 'inactive') {
          final blob = html.Blob(_chunks, mediaFormat);
          _completer?.complete(html.Url.createObjectUrlFromBlob(blob));
          _completer = null;
        }
      });
      _recorder.onError.listen((error) {
        _completer?.completeError(error);
        _completer = null;
        value = value.copyWith(isRecordingVideo: false);
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
    html.window.requestAnimationFrame(draw);
  }

  String get mediaFormat {
    if (browser.isSafari) {
      return 'video/mpeg4';
    }
    return 'video/webm';
  }

  /// Stop recording.

  @override
  Future<void> stop() async {
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

    _gainNode?.disconnect();
    audioSources?.forEach((source) {
      source.sourceNode.disconnect();
    });
    audioSources = [];
    _audioDestinationNode?.disconnect();
    _audioDestinationNode = null;
    _audioContext?.close();
    _audioContext = null;
    _videoMixer?.release();
    _videoMixer = null;
    value = RecorderValue.uninitialized();
  }
}
