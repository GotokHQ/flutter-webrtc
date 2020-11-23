#import "FlutterWebRTCPlugin.h"


@interface FlutterWebRTCPlugin (RTCRtpSender)

-(void) peerConnectionSenderReplaceTrack:(NSString *)senderId
                                   track: (RTCMediaStreamTrack *)track
                          peerConnection:(RTCPeerConnection*)peerConnection
                                  result:(FlutterResult)result;

-(void) peerConnectionSenderSetEncoding:(NSString *)senderId
                         peerConnection:(RTCPeerConnection*)peerConnection
                         maxBitrateKbps:(NSNumber *)maxBitrateKbps
                         minBitrateKbps:(NSNumber *)minBitrateKbps
                           maxFramerate:(NSNumber *)maxFramerate
                  scaleResolutionDownBy:(NSNumber *)scaleResolutionDownBy
                                 result:(FlutterResult)result;
@end
