import 'package:flutter/material.dart';

import '../interface/enums.dart';
import '../interface/rtc_video_renderer.dart';
import '../rtc_video_renderer.dart';
import 'rtc_video_renderer_impl.dart';

class RTCVideoView extends StatelessWidget {
  RTCVideoView(
    this._renderer, {
    Key? key,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    this.mirror = false,
    this.filterQuality = FilterQuality.low,
  }) : super(key: key);

  final RTCVideoRenderer _renderer;
  final RTCVideoViewObjectFit objectFit;
  final bool mirror;
  final FilterQuality filterQuality;

  RTCVideoRendererNative get videoRenderer =>
      _renderer.delegate as RTCVideoRendererNative;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RTCVideoValue>(
      valueListenable: videoRenderer,
      builder: (BuildContext context, RTCVideoValue value, Widget? _) {
        if (!value.initialized || !value.renderVideo || value.mute) {
          return Container();
        }
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return Center(
              child: Container(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                child: FittedBox(
                  fit: objectFit ==
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                      ? BoxFit.contain
                      : BoxFit.cover,
                  child: SizedBox(
                    //aspectRatio: value.aspectRatio,
                    width: value.rotation == 90 || value.rotation == 270
                        ? value.size.height
                        : value.size.width,
                    height: value.rotation == 90 || value.rotation == 270
                        ? value.size.width
                        : value.size.height,
                    child: Texture(
                      textureId: videoRenderer.textureId!,
                      filterQuality: filterQuality,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// class RTCVideoView extends StatelessWidget {
//   RTCVideoView(
//     this._renderer, {
//     Key key,
//     this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
//     this.mirror = false,
//   })  : assert(objectFit != null),
//         assert(mirror != null),
//         super(key: key);

//   final RTCVideoRenderer _renderer;
//   final RTCVideoViewObjectFit objectFit;
//   final bool mirror;

//   RTCVideoRendererNative get videoRenderer =>
//       _renderer.delegate as RTCVideoRendererNative;

//   @override
//   Widget build(BuildContext context) {
//     return LayoutBuilder(
//         builder: (BuildContext context, BoxConstraints constraints) =>
//             _buildVideoView(constraints));
//   }

//   Widget _buildVideoView(BoxConstraints constraints) {
//     return Center(
//       child: Container(
//         width: constraints.maxWidth,
//         height: constraints.maxHeight,
//         child: FittedBox(
//           fit: objectFit == RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
//               ? BoxFit.contain
//               : BoxFit.cover,
//           child: Center(
//             child: ValueListenableBuilder<RTCVideoValue>(
//               valueListenable: videoRenderer,
//               builder:
//                   (BuildContext context, RTCVideoValue value, Widget child) {
//                 return SizedBox(
//                   width: constraints.maxHeight * value.aspectRatio,
//                   height: constraints.maxHeight,
//                   child: value.renderVideo ? child : Container(),
//                 );
//               },
//               child: Transform(
//                 transform: Matrix4.identity()..rotateY(mirror ? -pi : 0.0),
//                 alignment: FractionalOffset.center,
//                 child: videoRenderer.textureId != null
//                     ? Texture(textureId: videoRenderer.textureId)
//                     : Container(),
//               ),
//             ),
//           ),
//         ),
//       ),
//     );
//   }
// }
