import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../interface/media_stream.dart';
import '../interface/rtc_video_renderer.dart';
import 'utils.dart';

class RTCVideoRendererNative extends VideoRenderer {
  RTCVideoRendererNative();
  final _channel = WebRTC.methodChannel();
  late int _textureId;
  MediaStream? _srcObject;
  late StreamSubscription<dynamic> _eventSubscription;
  bool _isReleased = false;
  final Completer<void> _creatingCompleter = Completer<void>();
  RTCVideoAppLifeCycleObserver? _lifeCycleObserver;

  bool get isCreated => _creatingCompleter.isCompleted;
  @override
  Future<void> initialize() async {
    if (isCreated) return;
    _lifeCycleObserver?.dispose();
    _lifeCycleObserver = RTCVideoAppLifeCycleObserver(this);
    _lifeCycleObserver?.initialize();

    final response = await _channel.invokeMethod('createVideoRenderer');
    _textureId = response['textureId'];
    _eventSubscription = _eventChannelFor(_textureId)
        .receiveBroadcastStream()
        .listen(eventListener, onError: errorListener);
    _creatingCompleter.complete(null);
    _applyStream();
  }

  @override
  int get videoWidth => value.size.width.toInt();

  @override
  int get videoHeight => value.size.height.toInt();

  @override
  int? get textureId => _textureId;

  @override
  MediaStream? get srcObject => _srcObject;

  @override
  bool operator ==(dynamic other) {
    if (identical(this, other)) return true;
    if (runtimeType != other.runtimeType) return false;
    return other.hashCode == hashCode;
  }

  @override
  int get hashCode => textureId.hashCode;

  EventChannel _eventChannelFor(int textureId) {
    return EventChannel('FlutterWebRTC/Texture$textureId');
  }

  @override
  set srcObject(MediaStream? stream) {
    if (textureId == null) throw 'Call initialize before setting the stream';
    _srcObject = stream;
    _applyStream();
  }

  void _applyStream() {
    if (!isCreated || _isReleased) {
      return;
    }
    if (textureId == null) throw 'Call initialize before setting the stream';
    print('APPLY STREAM: $_srcObject');
    _channel.invokeMethod('videoRendererSetSrcObject', <String, dynamic>{
      'textureId': textureId,
      'streamId': _srcObject?.id ?? '',
      'ownerTag': _srcObject?.ownerTag ?? ''
    }).then((_) {
      print('DONE APPLY STREAM: $_srcObject');
      value = (_srcObject == null)
          ? value.copyWith(renderVideo: renderVideo, mute: true)
          : value.copyWith(renderVideo: renderVideo, mute: false);
    });
  }

  @override
  Future<void> dispose() async {
    await release();
    await super.dispose();
  }

  @override
  Future<void> release() async {
    await _creatingCompleter.future;
    if (!_isReleased) {
      await _eventSubscription.cancel();
      await _channel.invokeMethod(
        'videoRendererDispose',
        <String, dynamic>{'textureId': _textureId},
      );
      _lifeCycleObserver?.dispose();
      _isReleased = true;
      value = RTCVideoValue.uninitialized();
    }
  }

  void eventListener(dynamic event) {
    final Map<dynamic, dynamic> map = event;
    print('map: $map');
    switch (map['event']) {
      case 'didTextureChangeRotation':
        value = value.copyWith(rotation: map['rotation']);
        break;
      case 'didTextureChangeVideoSize':
        value = value.copyWith(
          size: Size(map['width']?.toDouble() ?? 0.0,
              map['height']?.toDouble() ?? 0.0),
        );
        break;
      case 'didFirstFrameRendered':
        value = value.copyWith(firstFrameRendered: true);
        break;
    }
  }

  void errorListener(Object obj) {
    if (obj is Exception) {
      throw obj;
    }
  }

  @override
  bool get renderVideo => srcObject != null;

  @override
  bool get muted => value.mute;

  @override
  set muted(bool mute) {
    if (_isReleased) {
      return;
    }

    if (value.mute == mute) {
      return;
    }
    final old = value.mute;
    value = value.copyWith(mute: mute);
    _channel.invokeMethod(
      'videoRendererSetMuted',
      <String, dynamic>{'textureId': _textureId, 'mute': mute},
    ).catchError((error) {
      print('error: $error');
      value = value.copyWith(mute: old);
    });
  }

  @override
  bool get blurred => value.isBlurred;

  @override
  set blurred(bool blur) {
    if (_isReleased) {
      return;
    }

    if (value.isBlurred == blur) {
      return;
    }
    final old = value.isBlurred;
    value = value.copyWith(isBlurred: blur);
    _channel.invokeMethod(
      'videoRendererSetBlurred',
      <String, dynamic>{'textureId': _textureId, 'blur': blur},
    ).catchError((error) {
      print('error: $error');
      value = value.copyWith(mute: old);
    });
  }

  @override
  bool get mirror => value.isMirrored;

  @override
  set mirror(bool mirror) {
    if (_isReleased) {
      return;
    }

    if (value.isMirrored == mirror) {
      return;
    }
    //final old = value.isBlurred;
    value = value.copyWith(isMirrored: mirror);
    // _channel.invokeMethod(
    //   'videoRendererSetBlurred',
    //   <String, dynamic>{'textureId': _textureId, 'blur': blur},
    // ).catchError((error) {
    //   print('error: $error');
    //   value = value.copyWith(mute: old);
    // });
  }

  @override
  Future<bool> audioOutput(String deviceId) {
    // TODO(cloudwebrtc): related to https://github.com/flutter-webrtc/flutter-webrtc/issues/395
    throw UnimplementedError('This is not implement yet');
  }
}
