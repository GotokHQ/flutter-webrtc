//
//  FlutterRTCRtpSender.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 7/27/19.
//

#import "FlutterRTCRtpSender.h"

@implementation FlutterWebRTCPlugin (RTCRtpSender)
-(void) peerConnectionSenderReplaceTrack:(NSString *)senderId
                                   track:(RTCMediaStreamTrack *)track
                          peerConnection:(RTCPeerConnection*)peerConnection
                                  result:(FlutterResult)result {
    RTCRtpSender* sender;
    for (RTCRtpSender* s in peerConnection.senders) {
        if (s.senderId && [s.senderId isEqualToString:senderId]) {
            sender = s;
            break;
        }
    }
    if (sender) {
        [sender setTrack:track];
        result(nil);
    } else {
        result([FlutterError errorWithCode:@"peerConnectionSenderReplaceTrackFailed"
                                   message:@"sender is null"
                                   details:nil]);
    }
}

-(void) peerConnectionSenderSetEncoding:(NSString *)senderId
                         peerConnection:(RTCPeerConnection*)peerConnection
                         maxBitrateKbps:(NSNumber *)maxBitrateKbps
                         minBitrateKbps:(NSNumber *)minBitrateKbps
                           maxFramerate:(NSNumber *)maxFramerate
                  scaleResolutionDownBy:(NSNumber *)scaleResolutionDownBy
                                 result:(FlutterResult)result {
    RTCRtpSender* sender;
    for (RTCRtpSender* s in peerConnection.senders) {
        if (s.senderId && [s.senderId isEqualToString:senderId]) {
            sender = s;
            break;
        }
    }
    if (sender) {
        if (sender.parameters.encodings.count == 0) {
            NSLog(@"SenderSetEncoding RtpParameters are not read");
            result([FlutterError errorWithCode:@"peerConnectionSenderSetEncodingFailed"
                                       message:@"RtpParameters are not ready"
                                       details:nil]);
            return;
        }
        RTCRtpParameters *parameters = sender.parameters;
        for (RTCRtpEncodingParameters * encoding in parameters.encodings) {
            if (maxBitrateKbps) {
                encoding.maxBitrateBps = [maxBitrateKbps intValue] >= 0 ? [NSNumber numberWithInteger:[maxBitrateKbps intValue] * 1000] : nil;
            }
            if (minBitrateKbps) {
                encoding.minBitrateBps = [minBitrateKbps intValue] >= 0 ? [NSNumber numberWithInteger:[minBitrateKbps intValue] * 1000]: nil;
            }
            if (maxFramerate) {
                encoding.maxFramerate = [maxFramerate intValue] >= 0 ? maxFramerate : nil;
            }
            if (scaleResolutionDownBy) {
                encoding.scaleResolutionDownBy = [scaleResolutionDownBy intValue] >= 0 ? scaleResolutionDownBy : nil;
            }
        }
        sender.parameters = parameters;
        result(nil);
    } else {
        result([FlutterError errorWithCode:@"peerConnectionSenderSetEncodingFailed"
                                   message:@"sender is null"
                                   details:nil]);
    }
}

@end
