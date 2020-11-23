#import "FlutterWebRTCPlugin.h"
#import "FlutterRTCPeerConnection.h"
#import "FlutterRTCMediaStream.h"
#import "FlutterRTCDataChannel.h"
#import "FlutterRTCVideoRenderer.h"
#import "MediaRecorder.h"
#import "FlutterRTCVideoRecorder.h"
#import "FlutterRecorder.h"
#import "FlutterWebRTCPlugin.h"
#import "FlutterRTCVideoSource.h"
#import "FlutterVideoCapturer.h"
#import "SamplesInterceptor.h"
#import "FlutterAudioMixer.h"

#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

void runAsyncOnQueue(dispatch_queue_t queue, void (^block)(void))
{
    dispatch_async(queue, block);
}


@implementation FlutterWebRTCPlugin {
    FlutterMethodChannel *_methodChannel;
    SamplesInterceptor *_audioSamplesInterceptor;
    id _registry;
    id _messenger;
    id _textures;
    BOOL _speakerOn;
    FlutterAudioMixer *_audioMixerDevice;
}

@synthesize messenger = _messenger;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"FlutterWebRTC.Method"
                                     binaryMessenger:[registrar messenger]];
#if TARGET_OS_IPHONE
    UIViewController *viewController = (UIViewController *)registrar.messenger;
#endif
    FlutterWebRTCPlugin* instance = [[FlutterWebRTCPlugin alloc] initWithChannel:channel
                                                                       registrar:registrar
                                                                       messenger:[registrar messenger]
#if TARGET_OS_IPHONE
                                                                  viewController:viewController
#endif
                                                                    withTextures:[registrar textures]];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithChannel:(FlutterMethodChannel *)channel
                      registrar:(NSObject<FlutterPluginRegistrar>*)registrar
                      messenger:(NSObject<FlutterBinaryMessenger>*)messenger
#if TARGET_OS_IPHONE
                 viewController:(UIViewController *)viewController
#endif
                   withTextures:(NSObject<FlutterTextureRegistry> *)textures{

    self = [super init];
    
    if (self) {
        _methodChannel = channel;
        _registry = registrar;
        _textures = textures;
        _messenger = messenger;
        _speakerOn = NO;
#if TARGET_OS_IPHONE
        self.viewController = viewController;
#endif
        _dispatchQueue = dispatch_queue_create("cloudwebrtc.com/WebRTC.Queue", NULL);
        _cameraListeners = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsOpaquePersonality];
    }
    //RTCSetMinDebugLogLevel(RTCLoggingSeverityVerbose);
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    
//    _peerConnectionFactory = [[RTCPeerConnectionFactory alloc]
//                              initWithEncoderFactory:encoderFactory
//                              decoderFactory:decoderFactory];
    
    _audioMixerDevice = [[FlutterAudioMixer alloc] init];
    RCPeerConnectionFactoryBuilder *builder = [[RCPeerConnectionFactoryBuilder alloc] init];
    [builder setAudioDeviceModule:_audioMixerDevice.adm];
    [builder setVideoEncoderFactory:encoderFactory];
    [builder setVideoDecoderFactory:decoderFactory];
    _peerConnectionFactory = [builder createPeerConnectionFactory];
    
    self.peerConnections = [NSMutableDictionary new];
    self.localStreams = [NSMutableDictionary new];
    self.localTracks = [NSMutableDictionary new];
    self.renders = [[NSMutableDictionary alloc] init];
    _audioSamplesInterceptor = [[SamplesInterceptor alloc] init];
    
    RTCAudioSessionConfiguration *webRTCConfig =
    [RTCAudioSessionConfiguration webRTCConfiguration];
    webRTCConfig.categoryOptions = webRTCConfig.categoryOptions |
    AVAudioSessionCategoryOptionDefaultToSpeaker;
    [RTCAudioSessionConfiguration setWebRTCConfiguration:webRTCConfig];
    
    
    RTCAudioSession *session = [RTCAudioSession sharedInstance];
    [session addDelegate:self];
    
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didSessionRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
#endif
    return self;
}


- (void)didSessionRouteChange:(NSNotification *)notification {
#if TARGET_OS_IPHONE
  NSDictionary *interuptionDict = notification.userInfo;
  NSInteger routeChangeReason = [[interuptionDict valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];

  switch (routeChangeReason) {
      case AVAudioSessionRouteChangeReasonCategoryChange: {
          NSError* error;
          [[AVAudioSession sharedInstance] overrideOutputAudioPort:_speakerOn? AVAudioSessionPortOverrideSpeaker : AVAudioSessionPortOverrideNone error:&error];
      }
      break;

    default:
      break;
  }
#endif
}

#pragma mark - RTCAudioSessionDelegate

- (void)audioSessionDidStartPlayOrRecord:(RTCAudioSession *)session {
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeMain
                                 block:^{
        NSLog(@"audioSessionDidStartPlayOrRecord");
        session.isAudioEnabled = YES;
    }];
}

- (void)audioSessionDidStopPlayOrRecord:(RTCAudioSession *)session {
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeMain
                                 block:^{
        NSLog(@"audioSessionDidStopPlayOrRecord");
    }];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult) result {

    if ([@"createPeerConnection" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSDictionary* configuration = argsMap[@"configuration"];
        NSDictionary* constraints = argsMap[@"constraints"];
        
        RTCPeerConnection *peerConnection = [self.peerConnectionFactory
                                             peerConnectionWithConfiguration:[self RTCConfiguration:configuration]
                                             constraints:[self parseMediaConstraints:constraints]
                                             delegate:self];
        
        peerConnection.remoteStreams = [NSMutableDictionary new];
        peerConnection.remoteTracks = [NSMutableDictionary new];
        peerConnection.dataChannels = [NSMutableDictionary new];
        
        NSString *peerConnectionId = [[NSUUID UUID] UUIDString];
        peerConnection.flutterId  = peerConnectionId;
        
        /*Create Event Channel.*/
        peerConnection.eventChannel = [FlutterEventChannel
                                       eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/peerConnectoinEvent%@", peerConnectionId]
                                       binaryMessenger:_messenger];
        [peerConnection.eventChannel setStreamHandler:peerConnection];
        
        self.peerConnections[peerConnectionId] = peerConnection;
        result(@{ @"peerConnectionId" : peerConnectionId});
    } else if ([@"getUserMedia" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSDictionary* constraints = argsMap[@"constraints"];
        [self getUserMedia:constraints result:result];
    } else if ([@"getDisplayMedia" isEqualToString:call.method]) {
#if TARGET_OS_IPHONE
        NSDictionary* argsMap = call.arguments;
        NSDictionary* constraints = argsMap[@"constraints"];
        [self getDisplayMedia:constraints result:result];
#else
        result(FlutterMethodNotImplemented);
#endif
    } else if ([@"createLocalMediaStream" isEqualToString:call.method]) {
        [self createLocalMediaStream:result];
    } else if ([@"getSources" isEqualToString:call.method]) {
        [self getSources:result];
    } else if ([@"mediaStreamGetTracks" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* streamId = argsMap[@"streamId"];
        [self mediaStreamGetTracks:streamId result:result];
    } else if ([@"createOffer" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSDictionary* constraints = argsMap[@"constraints"];
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection)
        {
            [self peerConnectionCreateOffer:constraints peerConnection:peerConnection result:result ];
        }else{
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                       details:nil]);
        }
    } else if ([@"createAnswer" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSDictionary * constraints = argsMap[@"constraints"];
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection)
        {
            [self peerConnectionCreateAnswer:constraints
                              peerConnection:peerConnection
                                      result:result];
        }else{
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                       details:nil]);
        }
    } else if ([@"addStream" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        
        NSString* streamId = ((NSString*)argsMap[@"streamId"]);
        RTCMediaStream *stream = self.localStreams[streamId];
        
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        
        if(peerConnection && stream){
            [peerConnection addStream:stream];
            result(@"");
        }else{
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection or mediaStream not found!"]
                                       details:nil]);
        }
    } else if ([@"removeStream" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        
        NSString* streamId = ((NSString*)argsMap[@"streamId"]);
        RTCMediaStream *stream = self.localStreams[streamId];
        
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        
        if(peerConnection && stream){
            [peerConnection removeStream:stream];
            result(nil);
        }else{
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection or mediaStream not found!"]
                                       details:nil]);
        }
    } else if ([@"captureFrame" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* path = argsMap[@"path"];
        NSString* trackId = argsMap[@"trackId"];

        RTCMediaStreamTrack *track = [self trackForId: trackId];
        if (track != nil && [track isKindOfClass:[RTCVideoTrack class]]) {
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            [self mediaStreamTrackCaptureFrame:videoTrack toPath:path result:result];
        } else {
            if (track == nil) {
                result([FlutterError errorWithCode:@"Track is nil" message:nil details:nil]);
            } else {
                result([FlutterError errorWithCode:[@"Track is class of " stringByAppendingString:[[track class] description]] message:nil details:nil]);
            }
        }
    } else if ([@"setLocalDescription" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        NSDictionary *descriptionMap = argsMap[@"description"];
        NSString* sdp = descriptionMap[@"sdp"];
        RTCSdpType sdpType = [RTCSessionDescription typeForString:descriptionMap[@"type"]];
        RTCSessionDescription* description = [[RTCSessionDescription alloc] initWithType:sdpType sdp:sdp];
        if(peerConnection)
        {
            [self peerConnectionSetLocalDescription:description peerConnection:peerConnection result:result];
        }else{
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                       details:nil]);
        }
    } else if ([@"setRemoteDescription" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        NSDictionary *descriptionMap = argsMap[@"description"];
        NSString* sdp = descriptionMap[@"sdp"];
        RTCSdpType sdpType = [RTCSessionDescription typeForString:descriptionMap[@"type"]];
        RTCSessionDescription* description = [[RTCSessionDescription alloc] initWithType:sdpType sdp:sdp];
        
        if(peerConnection)
        {
            [self peerConnectionSetRemoteDescription:description peerConnection:peerConnection result:result];
        }else{
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                       details:nil]);
        }
    } else if ([@"sendDtmf" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* tone = argsMap[@"tone"];
        int duration = ((NSNumber*)argsMap[@"duration"]).intValue;
        int interToneGap = ((NSNumber*)argsMap[@"gap"]).intValue;
        
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection) {
   
             RTCRtpSender* audioSender = nil ;
            for( RTCRtpSender *rtpSender in peerConnection.senders){
                if([[[rtpSender track] kind] isEqualToString:@"audio"]) {
                    audioSender = rtpSender;
                }
            }
            if(audioSender){
            NSOperationQueue *queue = [[NSOperationQueue alloc] init];
            [queue addOperationWithBlock:^{
                double durationMs = duration / 1000.0;
                double interToneGapMs = interToneGap / 1000.0;
                [audioSender.dtmfSender insertDtmf :(NSString *)tone
                duration:(NSTimeInterval) durationMs interToneGap:(NSTimeInterval)interToneGapMs];
                NSLog(@"DTMF Tone played ");
            }];
            }
            
            result(@{@"result": @"success"});
        } else {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                       details:nil]);
        }
    } else if ([@"addCandidate" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSDictionary* candMap = argsMap[@"candidate"];
        NSString *sdp = candMap[@"candidate"];
        int sdpMLineIndex = ((NSNumber*)candMap[@"sdpMLineIndex"]).intValue;
        NSString *sdpMid = candMap[@"sdpMid"];
    
        RTCIceCandidate* candidate = [[RTCIceCandidate alloc] initWithSdp:sdp sdpMLineIndex:sdpMLineIndex sdpMid:sdpMid];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        
        if(peerConnection)
        {
            [self peerConnectionAddICECandidate:candidate peerConnection:peerConnection result:result];
        }else{
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                       details:nil]);
        }
    } else if ([@"getStats" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* trackId = argsMap[@"trackId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection)
            return [self peerConnectionGetStats:trackId peerConnection:peerConnection result:result];
        result(nil);
    } else if ([@"createDataChannel" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* label = argsMap[@"label"];
        NSDictionary * dataChannelDict = (NSDictionary*)argsMap[@"dataChannelDict"];
        [self createDataChannel:peerConnectionId
                          label:label
                         config:[self RTCDataChannelConfiguration:dataChannelDict]
                      messenger:_messenger];
        result(nil);
    } else if ([@"dataChannelSend" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSNumber* dataChannelId = argsMap[@"dataChannelId"];
        NSString* type = argsMap[@"type"];
        id data = argsMap[@"data"];
        
        [self dataChannelSend:peerConnectionId
                dataChannelId:dataChannelId
                         data:data
                         type:type];
        result(nil);
    } else if ([@"dataChannelClose" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* dataChannelId = argsMap[@"dataChannelId"];
        [self dataChannelClose:peerConnectionId
                 dataChannelId:dataChannelId];
        result(nil);
    } else if ([@"streamDispose" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* streamId = argsMap[@"streamId"];
        RTCMediaStream *stream = self.localStreams[streamId];
        if (stream) {
            for (RTCVideoTrack *track in stream.videoTracks) {
                [self.localTracks removeObjectForKey:track.trackId];
                RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
                [self mediaStreamTrackDispose:videoTrack];
            }
            for (RTCAudioTrack *track in stream.audioTracks) {
                [self.localTracks removeObjectForKey:track.trackId];
                [self mediaStreamTrackDispose:track];
            }
            [self.localStreams removeObjectForKey:streamId];
        }
        result(nil);
    } else if ([@"mediaStreamTrackSetEnable" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        NSNumber* enabled = argsMap[@"enabled"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            track.isEnabled = enabled.boolValue;
        }
        result(nil);
    } else if ([@"mediaStreamAddTrack" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* streamId = argsMap[@"streamId"];
        NSString* trackId = argsMap[@"trackId"];

        RTCMediaStream *stream = self.localStreams[streamId];
        if (stream) {
            RTCMediaStreamTrack *track = self.localTracks[trackId];
            if(track != nil) {
                if([track isKindOfClass:[RTCAudioTrack class]]) {
                    RTCAudioTrack *audioTrack = (RTCAudioTrack *)track;
                    [stream addAudioTrack:audioTrack];
                } else if ([track isKindOfClass:[RTCVideoTrack class]]){
                    RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
                    [stream addVideoTrack:videoTrack];
                }
            } else {
                result([FlutterError errorWithCode:@"mediaStreamAddTrack: Track is nil" message:nil details:nil]);
            }
        } else {
            result([FlutterError errorWithCode:@"mediaStreamAddTrack: Stream is nil" message:nil details:nil]);
        }
        result(nil);
    } else if([@"mediaStreamTrackRestartCamera" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackRestartCamera:track result:result];
            return;
        }
        result(nil);
    } else if([@"mediaStreamTrackStop" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackStop:track result:result];
            return;
        }
        result(nil);
    } else if([@"mediaStreamTrackStart" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackStart:track result:result];
            return;
        }
        result(nil);
    } else if([@"mediaStreamTrackAdaptOutputFormat" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        NSNumber* width = argsMap[@"width"];
        NSNumber* height = argsMap[@"height"];
        NSNumber* frameRate = argsMap[@"frameRate"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackAdaptOutputFormat:track width:[width intValue] height:[height intValue] frameRate:[frameRate intValue] result:result];
            return;
        }
        result(nil);
    } else if ([@"mediaStreamRemoveTrack" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* streamId = argsMap[@"streamId"];
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStream *stream = self.localStreams[streamId];
        if (stream) {
            RTCMediaStreamTrack *track = self.localTracks[trackId];
            if(track != nil) {
                if([track isKindOfClass:[RTCAudioTrack class]]) {
                    RTCAudioTrack *audioTrack = (RTCAudioTrack *)track;
                    [stream removeAudioTrack:audioTrack];
                } else if ([track isKindOfClass:[RTCVideoTrack class]]){
                    RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
                    [stream removeVideoTrack:videoTrack];
                }
            } else {
                result([FlutterError errorWithCode:@"mediaStreamRemoveTrack: Track is nil" message:nil details:nil]);
            }
        } else {
            result([FlutterError errorWithCode:@"mediaStreamRemoveTrack: Stream is nil" message:nil details:nil]);
        }
        result(nil);
    } else if ([@"trackDispose" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = [self trackForId:trackId];
        [self mediaStreamTrackDispose:track];
        result(nil);
    } else if ([@"peerConnectionClose" isEqualToString:call.method] || [@"peerConnectionDispose" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if (peerConnection) {
            [peerConnection close];
            [self.peerConnections removeObjectForKey:peerConnectionId];
            
            // Clean up peerConnection's streams and tracks
            [peerConnection.remoteStreams removeAllObjects];
            [peerConnection.remoteTracks removeAllObjects];
            
            // Clean up peerConnection's dataChannels.
            NSMutableDictionary<NSNumber *, RTCDataChannel *> *dataChannels = peerConnection.dataChannels;
            for (NSNumber *dataChannelId in dataChannels) {
                dataChannels[dataChannelId].delegate = nil;
                // There is no need to close the RTCDataChannel because it is owned by the
                // RTCPeerConnection and the latter will close the former.
            }
            [dataChannels removeAllObjects];
        }
        result(nil);
    } else if ([@"createVideoRenderer" isEqualToString:call.method]){
        NSLog(@"createVideoRenderer_native");
        FlutterRTCVideoRenderer* render = [self createWithTextureRegistry:_textures];
        self.renders[@(render.textureId)] = render;
        result(@{@"textureId": @(render.textureId)});
    } else if ([@"videoRendererDispose" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *textureId = argsMap[@"textureId"];
        FlutterRTCVideoRenderer *render = self.renders[textureId];
        [self removeCameraListener:(id<CameraSwitchObserver>)render];
        render.videoTrack = nil;
        [render dispose];
        [self.renders removeObjectForKey:textureId];
        result(nil);
    } else if ([@"videoRendererSetSrcObject" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *textureId = argsMap[@"textureId"];
        FlutterRTCVideoRenderer *render = self.renders[textureId];
        NSString *streamId = argsMap[@"streamId"];
        NSString *ownerTag = argsMap[@"ownerTag"];
        if(!render) {
            result([FlutterError errorWithCode:@"videoRendererSetSrcObject: render is nil" message:nil details:nil]);
            return;
        }
        RTCMediaStream *stream = nil;
        RTCVideoTrack* videoTrack = nil;
        if([ownerTag isEqualToString:@"local"]){
            stream = _localStreams[streamId];
        }
        if(!stream){
            stream = [self streamForId:streamId peerConnectionId:ownerTag];
        }
        if(stream){
            NSArray *videoTracks = stream ? stream.videoTracks : nil;
            videoTrack = videoTracks && videoTracks.count ? videoTracks[0] : nil;
            if (!videoTrack) {
                NSLog(@"Not found video track for RTCMediaStream: %@", streamId);
            }
        }
        [self rendererSetSrcObject:render stream:videoTrack];
        result(nil);
    } else if ([@"videoRendererSetMuted" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *textureId = argsMap[@"textureId"];
        NSNumber *mute  = argsMap[@"mute"];
        NSLog(@"mute %@", mute);
        BOOL isMute = [mute boolValue];
        FlutterRTCVideoRenderer *render = self.renders[textureId];
        if(render){
            render.mute = isMute;
        }
        result(nil);
    } else if ([@"videoRendererSetBlurred" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *textureId = argsMap[@"textureId"];
        NSNumber *blur  = argsMap[@"blur"];
        NSLog(@"blur %@", blur);
        BOOL isBlur = [blur boolValue];
        FlutterRTCVideoRenderer *render = self.renders[textureId];
        if(render){
            render.blur = isBlur;
        }
        result(nil);
    }  else if ([@"mediaStreamTrackHasTorch" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if (track != nil && [track isKindOfClass:[RTCVideoTrack class]]) {
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            [self mediaStreamTrackHasTorch:videoTrack result:result];
        } else {
            if (track == nil) {
                result([FlutterError errorWithCode:@"Track is nil" message:nil details:nil]);
            } else {
                result([FlutterError errorWithCode:[@"Track is class of " stringByAppendingString:[[track class] description]] message:nil details:nil]);
            }
        }
    } else if ([@"mediaStreamTrackSetTorch" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        BOOL torch = [argsMap[@"torch"] boolValue];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if (track != nil && [track isKindOfClass:[RTCVideoTrack class]]) {
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            [self mediaStreamTrackSetTorch:videoTrack torch:torch result:result];
        } else {
            if (track == nil) {
                result([FlutterError errorWithCode:@"Track is nil" message:nil details:nil]);
            } else {
                result([FlutterError errorWithCode:[@"Track is class of " stringByAppendingString:[[track class] description]] message:nil details:nil]);
            }
        }
    } else if ([@"mediaStreamTrackSwitchCamera" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackSwitchCamera:track result:result];
            return;
        }
        result(nil);
    } else if ([@"mediaStreamTrackAdaptOutputFormat" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        NSNumber* width = argsMap[@"width"];
        NSNumber* height = argsMap[@"height"];
        NSNumber* frameRate = argsMap[@"frameRate"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackAdaptOutputFormat:track width:[width intValue] height:[height intValue] frameRate:[frameRate intValue] result:result];
            return;
        }
        result(nil);
    } else if ([@"mediaStreamTrackRestartCamera" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackRestartCamera:track result:result];
            return;
        }
        result(nil);
    } else if ([@"mediaStreamTrackStart" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackStart:track result:result];
            return;
        }
        result(nil);
    } else if ([@"mediaStreamTrackStop" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if(track != nil){
            [self mediaStreamTrackStop:track result:result];
            return;
        }
        result(nil);
    } else if ([@"setVolume" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        NSNumber* volume = argsMap[@"volume"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if (track != nil && [track isKindOfClass:[RTCAudioTrack class]]) {
            RTCAudioTrack *audioTrack = (RTCAudioTrack *)track;
            RTCAudioSource *audioSource = audioTrack.source;
            audioSource.volume = [volume doubleValue];
        }
        result(nil);
    } else if ([@"setMicrophoneMute" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* trackId = argsMap[@"trackId"];
        NSNumber* mute = argsMap[@"mute"];
        RTCMediaStreamTrack *track = self.localTracks[trackId];
        if (track != nil && [track isKindOfClass:[RTCAudioTrack class]]) {
            RTCAudioTrack *audioTrack = (RTCAudioTrack *)track;
            audioTrack.isEnabled = !mute.boolValue;
        }
        result(nil);
    } else if ([@"enableSpeakerphone" isEqualToString:call.method]) {
#if TARGET_OS_IPHONE
        NSDictionary* argsMap = call.arguments;
        NSNumber* enable = argsMap[@"enable"];
        _speakerOn = enable.boolValue;
        [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeMain
                                     block:^{
            RTCAudioSession *session = [RTCAudioSession sharedInstance];
            
            BOOL hasSucceeded = NO;
            NSError *error = nil;
            
            [session lockForConfiguration];
            RTCAudioSessionConfiguration *webRTCConfig =
            [RTCAudioSessionConfiguration webRTCConfiguration];
            RTCAudioSessionConfiguration *configuration =
                [[RTCAudioSessionConfiguration alloc] init];
            configuration.category = webRTCConfig.category;
            configuration.categoryOptions = AVAudioSessionCategoryOptionAllowBluetooth |
            enable.boolValue ? AVAudioSessionCategoryOptionDefaultToSpeaker : 0;
            configuration.mode = webRTCConfig.mode;

            if (session.isActive) {
              hasSucceeded = [session setConfiguration:configuration error:&error];
            } else {
              hasSucceeded = [session setConfiguration:configuration
                                                active:YES
                                                 error:&error];
            }
            [session unlockForConfiguration];
            if (!hasSucceeded) {
                result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                           message:[NSString stringWithFormat:@"Error setting configuration: %@", error.localizedDescription]
                                           details:nil]);
                return;
            }
            result(nil);
        }];
#else
        result(FlutterMethodNotImplemented);
#endif
    } else if ([@"getLocalDescription" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection) {
            RTCSessionDescription* sdp = peerConnection.localDescription;
            NSString *type = [RTCSessionDescription stringForType:sdp.type];
            result(@{@"sdp": sdp.sdp, @"type": type});
        } else {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                       details:nil]);
        }
    } else if ([@"getRemoteDescription" isEqualToString:call.method]) {
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection) {
            RTCSessionDescription* sdp = peerConnection.remoteDescription;
            NSString *type = [RTCSessionDescription stringForType:sdp.type];
            result(@{@"sdp": sdp.sdp, @"type": type});
        } else {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                       details:nil]);
        }
    } else if ([@"setConfiguration" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSDictionary* configuration = argsMap[@"configuration"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection) {
            [self peerConnectionSetConfiguration:[self RTCConfiguration:configuration] peerConnection:peerConnection];
            result(nil);
        } else {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                           message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
                                           details:nil]);
        }
    } else if ([@"addTrack" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* trackId = argsMap[@"trackId"];
        NSArray* streamIds = argsMap[@"streamIds"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        
        RTCMediaStreamTrack *track = [self trackForId:trackId];
        if(track == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: track not found!"]
            details:nil]);
            return;
        }
        RTCRtpSender* sender = [peerConnection addTrack:track streamIds:streamIds];
        result([self rtpSenderToMap:sender]);
    } else if ([@"removeTrack" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* senderId = argsMap[@"senderId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpSender *sender = [self getRtpSenderById:peerConnection Id:senderId];
        if(sender == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: sender not found!"]
            details:nil]);
            return;
        }
        result(@{@"result": @([peerConnection removeTrack:sender])});
    } else if ([@"addTransceiver" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSDictionary* transceiverInit = argsMap[@"transceiverInit"];
        NSString* trackId = argsMap[@"trackId"];
        NSString* mediaType = argsMap[@"mediaType"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpTransceiver* transceiver = nil;
        
        if(trackId != nil) {
            RTCMediaStreamTrack *track = [self trackForId:trackId];
            if (transceiverInit != nil) {
                RTCRtpTransceiverInit *init = [self mapToTransceiverInit:transceiverInit];
                transceiver = [peerConnection addTransceiverWithTrack:track init:init];
            } else {
                transceiver = [peerConnection addTransceiverWithTrack:track];
            }
        } else if (mediaType != nil) {
             RTCRtpMediaType rtpMediaType = [self stringToRtpMediaType:mediaType];
            if (transceiverInit != nil) {
                RTCRtpTransceiverInit *init = [self mapToTransceiverInit:transceiverInit];
                transceiver = [peerConnection addTransceiverOfType:(rtpMediaType) init:init];
            } else {
                transceiver = [peerConnection addTransceiverOfType:rtpMediaType];
            }
        } else {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: Incomplete parameters!"]
            details:nil]);
            return;
        }
        
        if (transceiver == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: can't addTransceiver!"]
            details:nil]);
            return;
        }
        
        result([self transceiverToMap:transceiver]);
    } else if ([@"rtpTransceiverSetDirection" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* direction = argsMap[@"direction"];
        NSString* transceiverId = argsMap[@"transceiverId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpTransceiver *transcevier = [self getRtpTransceiverById:peerConnection Id:transceiverId];
        if(transcevier == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: transcevier not found!"]
            details:nil]);
            return;
        }
#if TARGET_OS_IPHONE
        [transcevier setDirection:[self stringToTransceiverDirection:direction] error:nil];
#elif TARGET_OS_MAC
        [transcevier setDirection:[self stringToTransceiverDirection:direction]];
#endif
        result(nil);
    } else if ([@"rtpTransceiverGetCurrentDirection" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* transceiverId = argsMap[@"transceiverId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpTransceiver *transcevier = [self getRtpTransceiverById:peerConnection Id:transceiverId];
        if(transcevier == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: transcevier not found!"]
            details:nil]);
            return;
        }
        result(@{@"result": [self transceiverDirectionString:transcevier.direction]});
    } else if ([@"rtpTransceiverStop" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* transceiverId = argsMap[@"transceiverId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpTransceiver *transcevier = [self getRtpTransceiverById:peerConnection Id:transceiverId];
        if(transcevier == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: transcevier not found!"]
            details:nil]);
            return;
        }
#if TARGET_OS_IPHONE
             [transcevier stopInternal];
#elif TARGET_OS_MAC
             [transcevier stop];
#endif
        result(nil);
    } else if ([@"rtpSenderSetParameters" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* senderId = argsMap[@"rtpSenderId"];
        NSDictionary* parameters = argsMap[@"parameters"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpSender *sender = [self getRtpSenderById:peerConnection Id:senderId];
        if(sender == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: sender not found!"]
            details:nil]);
            return;
        }
        [sender setParameters:[self updateRtpParameters: parameters : sender.parameters]];
        
        result(@{@"result": @(YES)});
    } else if ([@"rtpSenderReplaceTrack" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* senderId = argsMap[@"senderId"];
        NSString* trackId = argsMap[@"trackId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpSender *sender = [self getRtpSenderById:peerConnection Id:senderId];
        if(sender == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: sender not found!"]
            details:nil]);
            return;
        }
        RTCMediaStreamTrack *track = [self trackForId:trackId];
        if(track == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: track not found!"]
            details:nil]);
            return;
        }
        [sender setTrack:track];
        result(nil);
    } else if ([@"rtpSenderSetTrack" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* senderId = argsMap[@"senderId"];
        NSString* trackId = argsMap[@"trackId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpSender *sender = [self getRtpSenderById:peerConnection Id:senderId];
        if(sender == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: sender not found!"]
            details:nil]);
            return;
        }
        RTCMediaStreamTrack *track = [self trackForId:trackId];
        if(track == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: track not found!"]
            details:nil]);
            return;
        }
        [sender setTrack:track];
        result(nil);
    } else if ([@"rtpSenderDispose" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString* peerConnectionId = argsMap[@"peerConnectionId"];
        NSString* senderId = argsMap[@"senderId"];
        RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
        if(peerConnection == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: peerConnection not found!"]
            details:nil]);
            return;
        }
        RTCRtpSender *sender = [self getRtpSenderById:peerConnection Id:senderId];
        if(sender == nil) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
            message:[NSString stringWithFormat:@"Error: sender not found!"]
            details:nil]);
            return;
        }
        [peerConnection removeTrack:sender];
        result(nil);
    } else if ([@"startRecordToFile" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString *path = argsMap[@"path"];
        NSNumber *recorderId = argsMap[@"recorderId"];
        CGFloat width = [argsMap[@"width"] floatValue];
        CGFloat height = [argsMap[@"height"] floatValue];
        NSString *trackId = argsMap[@"videoTrackId"];
        NSString *type = argsMap[@"type"];
        CGSize size = CGSizeMake(width, height);
        NSNumber *audioOnly = argsMap[@"audioOnly"];
        BOOL isAudioOnly = [audioOnly boolValue];
        BOOL isRemote = NO;
        RTCMediaStreamTrack *track = _localTracks[trackId];
        if ((!track  || ![track isKindOfClass:[RTCVideoTrack class]]) && !isAudioOnly) {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:@"No track"
                                       details:nil]);
            return;
        }
        id<FlutterRecorder> recorder = (id<FlutterRecorder>)[[MediaRecorder alloc] initWithRecorderId:recorderId videoSize:size samplesInterceptor:_audioSamplesInterceptor messenger:_messenger audioOnly:isAudioOnly];
        if (track){
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            [recorder addVideoTrack:videoTrack isRemote:isRemote label:@"local"];
            NSLog(@"Successfully Added video track:%@ to recorder:%@", trackId, recorderId);
        }
        [self addCameraListener:recorder];
        self.mediaRecorders[recorderId] = recorder;
        [recorder startVideoRecordingAtPath:path result:result];
        NSLog(@"recorder: %@", recorder);
        NSLog(@"recorder type: %@", type);
    } else if ([@"stopRecordToFile" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *recorderId = argsMap[@"recorderId"];
        id<FlutterRecorder> recorder = self.mediaRecorders[recorderId];
        [self removeCameraListener:recorder];
        [recorder stopVideoRecordingWithResult:result];
    } else if ([@"createMultiPartyRecorder" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        CGFloat width = [argsMap[@"width"] floatValue];
        CGFloat height = [argsMap[@"height"] floatValue];
        int fps = [argsMap[@"fps"] intValue];
        NSString *type = argsMap[@"type"];
        CGSize size = CGSizeMake(width, height);
        NSNumber *recorderId = argsMap[@"recorderId"];
        NSNumber *audioOnly = argsMap[@"audioOnly"];
        BOOL isAudioOnly = [audioOnly boolValue];
        id<FlutterRecorder> recorder;
        if ([type isEqualToString:@"local"]) {
            recorder = (id<FlutterRecorder>)[[MediaRecorder alloc] initWithRecorderId:recorderId videoSize:size samplesInterceptor:_audioSamplesInterceptor messenger:_messenger audioOnly:isAudioOnly];
        } else if ([type isEqualToString:@"mixed"]) {
            recorder = (id<FlutterRecorder>)[[FlutterRTCVideoRecorder alloc] initWithRecorderId:recorderId videoSize:size framesPerSecond:fps messenger:_messenger  audioOnly:isAudioOnly];
            [_audioMixerDevice addAudioSamplesInterceptor:(id<SamplesInterceptorDelegate>)recorder];
        } else {
            result([FlutterError errorWithCode:[NSString stringWithFormat:@"%@Failed",call.method]
                                       message:[NSString stringWithFormat:@"Error: unknown recorder type!"]
                                       details:nil]);
            return;
        }
        [self addCameraListener:recorder];
        NSLog(@"recorder: %@", recorder);
        NSLog(@"recorder type: %@", type);
        self.mediaRecorders[recorderId] = recorder;
        result(@YES);
    } else if([@"addTrackToMultiPartyRecorder" isEqualToString:call.method]){
        NSLog(@"addTrackToMediaRecorder called");
        NSDictionary* argsMap = call.arguments;
        NSNumber *recorderId = argsMap[@"recorderId"];
        NSString *trackId = argsMap[@"trackId"];
        NSString *label = argsMap[@"label"];
        id<FlutterRecorder> recorder = self.mediaRecorders[recorderId];
        BOOL isRemote = NO;
        RTCMediaStreamTrack *track = _localTracks[trackId];
        if (!track) {
            track = [self trackForId:trackId];
            isRemote = YES;
        }
        if ([track isKindOfClass:[RTCVideoTrack class]]){
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            [recorder addVideoTrack:videoTrack isRemote:isRemote label:label];
            NSLog(@"Successfully Added video track:%@ to recorder:%@", trackId, recorderId);
        }
        result(@YES);
    } else if([@"removeTrackFromMultiPartyRecorder" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *recorderId = argsMap[@"recorderId"];
        NSString *trackId = argsMap[@"trackId"];
        NSString *label = argsMap[@"label"];
        id<FlutterRecorder> recorder = self.mediaRecorders[recorderId];
        if (trackId) {
            RTCMediaStreamTrack *track = _localTracks[trackId];
            BOOL isRemote = NO;
            if (!track) {
                track = [self trackForId:trackId];
                isRemote = YES;
            }
            if ([track isKindOfClass:[RTCVideoTrack class]]){
                RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
                [recorder removeVideoTrack:videoTrack isRemote:isRemote label:label];
                NSLog(@"Successfully Removed video track:%@ to recorder:%@", trackId, recorderId);
                result(@YES);
            }
        } else {
            [recorder removeVideoTrack:nil isRemote:NO label:nil];
            NSLog(@"Done Removing nil track");
        }
    } else if([@"pauseMultiPartyRecorder" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *recorderId = argsMap[@"recorderId"];
        NSLog(@"pauseMediaRecorder %@", recorderId);
        NSNumber *paused  = argsMap[@"paused"];
        NSLog(@"pausedn %@", paused);
        BOOL isPause = [paused boolValue];
        id<FlutterRecorder> recorder = self.mediaRecorders[recorderId];
        [recorder setPaused:isPause];
        result(nil);
    } else if([@"addTrackToMediaRecorder" isEqualToString:call.method]){
        NSLog(@"addTrackToMediaRecorder called");
        NSDictionary* argsMap = call.arguments;
        NSNumber *recorderId = argsMap[@"recorderId"];
        NSString *trackId = argsMap[@"trackId"];
        NSString *label = argsMap[@"label"];
        id<FlutterRecorder> recorder = self.mediaRecorders[recorderId];
        BOOL isRemote = NO;
        RTCMediaStreamTrack *track = _localTracks[trackId];
        if (!track) {
            track = [self trackForId:trackId];
            isRemote = YES;
        }
        if ([track isKindOfClass:[RTCVideoTrack class]]){
            RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
            [recorder addVideoTrack:videoTrack isRemote:isRemote label:label];
            NSLog(@"Successfully Added video track:%@ to recorder:%@", trackId, recorderId);
            result(@YES);
        }
    } else if([@"startMultiPartyRecorder" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSString *path = argsMap[@"path"];
        NSNumber *recorderId = argsMap[@"recorderId"];
        NSLog(@"startMediaRecorder called");
        NSLog(@"recorderId %@", recorderId);
        NSLog(@"path %@", path);
        id<FlutterRecorder> recorder = self.mediaRecorders[recorderId];
        if (!recorder) {
            NSLog(@"Did not find a recorder with recorderId %@", recorderId);
        }
        [recorder startVideoRecordingAtPath:path result:result];
    } else if([@"stopMultiPartyRecorder" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *recorderId = argsMap[@"recorderId"];
        id<FlutterRecorder> recorder = self.mediaRecorders[recorderId];
        [recorder stopVideoRecordingWithResult:result];
    } else if([@"disposeMultiPartyRecorder" isEqualToString:call.method]){
        NSDictionary* argsMap = call.arguments;
        NSNumber *recorderId = argsMap[@"recorderId"];
        id<FlutterRecorder> recorder = self.mediaRecorders[recorderId];
        [self->_audioSamplesInterceptor removeSampleInterceptor:(id<SamplesInterceptorDelegate>)recorder];
        [_audioMixerDevice removeAudioSamplesInterceptor:(id<SamplesInterceptorDelegate>)recorder];
        [self removeCameraListener:recorder];
        [recorder dispose];
        [self.mediaRecorders removeObjectForKey:recorderId];
        recorder = nil;
        NSLog(@"disposed record %@", recorderId);
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)dealloc
{
    [_localTracks removeAllObjects];
    _localTracks = nil;
    [_localStreams removeAllObjects];
    _localStreams = nil;
    
    for (NSString *peerConnectionId in _peerConnections) {
        RTCPeerConnection *peerConnection = _peerConnections[peerConnectionId];
        peerConnection.delegate = nil;
        [peerConnection close];
    }
    [_cameraListeners removeAllObjects];
    [_peerConnections removeAllObjects];
    _peerConnectionFactory = nil;
}


-(void)mediaStreamGetTracks:(NSString*)streamId
                     result:(FlutterResult)result {
    RTCMediaStream* stream = [self streamForId:streamId peerConnectionId:@""];
    if(stream){
        NSMutableArray *audioTracks = [NSMutableArray array];
        NSMutableArray *videoTracks = [NSMutableArray array];
        
        for (RTCMediaStreamTrack *track in stream.audioTracks) {
            NSString *trackId = track.trackId;
            [self.localTracks setObject:track forKey:trackId];
            [audioTracks addObject:@{
                                     @"enabled": @(track.isEnabled),
                                     @"id": trackId,
                                     @"kind": track.kind,
                                     @"label": trackId,
                                     @"readyState": @"live",
                                     @"remote": @(NO)
                                     }];
        }
        
        for (RTCMediaStreamTrack *track in stream.videoTracks) {
            NSString *trackId = track.trackId;
            [self.localTracks setObject:track forKey:trackId];
            [videoTracks addObject:@{
                                     @"enabled": @(track.isEnabled),
                                     @"id": trackId,
                                     @"kind": track.kind,
                                     @"label": trackId,
                                     @"readyState": @"live",
                                     @"remote": @(NO)
                                     }];
        }
        
        result(@{@"audioTracks": audioTracks, @"videoTracks" : videoTracks });
    }else{
        result(nil);
    }
}

- (RTCMediaStream*)streamForId:(NSString*)streamId peerConnectionId:(NSString *)peerConnectionId {
    RTCMediaStream *stream = nil;
    if (peerConnectionId.length > 0) {
        RTCPeerConnection *peerConnection = [_peerConnections objectForKey:peerConnectionId];
        stream = peerConnection.remoteStreams[streamId];
    } else {
        for (RTCPeerConnection *peerConnection in _peerConnections.allValues) {
            stream = peerConnection.remoteStreams[streamId];
            if (stream) {
                break;
            }
        }
    }
    if (!stream) {
        stream = _localStreams[streamId];
    }
    return stream;
}

- (RTCMediaStreamTrack*)trackForId:(NSString*)trackId {
    RTCMediaStreamTrack *track = _localTracks[trackId];
    if (!track) {
        for (RTCPeerConnection *peerConnection in _peerConnections.allValues) {
            track = peerConnection.remoteTracks[trackId];
            if (track) {
                break;
            }
        }
    }
    return track;
}



- (RTCIceServer *)RTCIceServer:(id)json
{
    if (!json) {
        NSLog(@"a valid iceServer value");
        return nil;
    }
    
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"must be an object");
        return nil;
    }
    
    NSArray<NSString *> *urls;
    if ([json[@"url"] isKindOfClass:[NSString class]]) {
        // TODO: 'url' is non-standard
        urls = @[json[@"url"]];
    } else if ([json[@"urls"] isKindOfClass:[NSString class]]) {
        urls = [json[@"urls"] componentsSeparatedByString:@","];
    } else {
        urls = (NSArray*)json[@"urls"];
    }
    
    if (json[@"username"] != nil || json[@"credential"] != nil) {
        return [[RTCIceServer alloc]initWithURLStrings:urls
                                              username:json[@"username"]
                                            credential:json[@"credential"]];
    }
    
    return [[RTCIceServer alloc] initWithURLStrings:urls];
}


- (nonnull RTCConfiguration *)RTCConfiguration:(id)json
{
   RTCConfiguration *config = [[RTCConfiguration alloc] init];

  if (!json) {
    return config;
  }

  if (![json isKindOfClass:[NSDictionary class]]) {
    NSLog(@"must be an object");
    return config;
  }

  if (json[@"audioJitterBufferMaxPackets"] != nil && [json[@"audioJitterBufferMaxPackets"] isKindOfClass:[NSNumber class]]) {
    config.audioJitterBufferMaxPackets = [json[@"audioJitterBufferMaxPackets"] intValue];
  }

  if (json[@"bundlePolicy"] != nil && [json[@"bundlePolicy"] isKindOfClass:[NSString class]]) {
    NSString *bundlePolicy = json[@"bundlePolicy"];
    if ([bundlePolicy isEqualToString:@"balanced"]) {
      config.bundlePolicy = RTCBundlePolicyBalanced;
    } else if ([bundlePolicy isEqualToString:@"max-compat"]) {
      config.bundlePolicy = RTCBundlePolicyMaxCompat;
    } else if ([bundlePolicy isEqualToString:@"max-bundle"]) {
      config.bundlePolicy = RTCBundlePolicyMaxBundle;
    }
  }

  if (json[@"iceBackupCandidatePairPingInterval"] != nil && [json[@"iceBackupCandidatePairPingInterval"] isKindOfClass:[NSNumber class]]) {
    config.iceBackupCandidatePairPingInterval = [json[@"iceBackupCandidatePairPingInterval"] intValue];
  }

  if (json[@"iceConnectionReceivingTimeout"] != nil && [json[@"iceConnectionReceivingTimeout"] isKindOfClass:[NSNumber class]]) {
    config.iceConnectionReceivingTimeout = [json[@"iceConnectionReceivingTimeout"] intValue];
  }

    if (json[@"iceServers"] != nil && [json[@"iceServers"] isKindOfClass:[NSArray class]]) {
        NSMutableArray<RTCIceServer *> *iceServers = [NSMutableArray new];
        for (id server in json[@"iceServers"]) {
            RTCIceServer *convert = [self RTCIceServer:server];
            if (convert != nil) {
                [iceServers addObject:convert];
            }
        }
        config.iceServers = iceServers;
    }

  if (json[@"iceTransportPolicy"] != nil && [json[@"iceTransportPolicy"] isKindOfClass:[NSString class]]) {
    NSString *iceTransportPolicy = json[@"iceTransportPolicy"];
    if ([iceTransportPolicy isEqualToString:@"all"]) {
      config.iceTransportPolicy = RTCIceTransportPolicyAll;
    } else if ([iceTransportPolicy isEqualToString:@"none"]) {
      config.iceTransportPolicy = RTCIceTransportPolicyNone;
    } else if ([iceTransportPolicy isEqualToString:@"nohost"]) {
      config.iceTransportPolicy = RTCIceTransportPolicyNoHost;
    } else if ([iceTransportPolicy isEqualToString:@"relay"]) {
      config.iceTransportPolicy = RTCIceTransportPolicyRelay;
    }
  }

  if (json[@"rtcpMuxPolicy"] != nil && [json[@"rtcpMuxPolicy"] isKindOfClass:[NSString class]]) {
    NSString *rtcpMuxPolicy = json[@"rtcpMuxPolicy"];
    if ([rtcpMuxPolicy isEqualToString:@"negotiate"]) {
      config.rtcpMuxPolicy = RTCRtcpMuxPolicyNegotiate;
    } else if ([rtcpMuxPolicy isEqualToString:@"require"]) {
      config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    }
  }

  if (json[@"tcpCandidatePolicy"] != nil && [json[@"tcpCandidatePolicy"] isKindOfClass:[NSString class]]) {
    NSString *tcpCandidatePolicy = json[@"tcpCandidatePolicy"];
    if ([tcpCandidatePolicy isEqualToString:@"enabled"]) {
      config.tcpCandidatePolicy = RTCTcpCandidatePolicyEnabled;
    } else if ([tcpCandidatePolicy isEqualToString:@"disabled"]) {
      config.tcpCandidatePolicy = RTCTcpCandidatePolicyDisabled;
    }
  }

  if (json[@"sdpSemantics"] != nil && [json[@"sdpSemantics"] isKindOfClass:[NSString class]]) {
    NSString *sdpSemantics = json[@"sdpSemantics"];
    if ([sdpSemantics isEqualToString:@"plan-b"]) {
      config.sdpSemantics = RTCSdpSemanticsPlanB;
    } else if ([sdpSemantics isEqualToString:@"unified-plan"]) {
      config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    }
  }

  return config;
}

- (RTCDataChannelConfiguration *)RTCDataChannelConfiguration:(id)json
{
    if (!json) {
        return nil;
    }
    if ([json isKindOfClass:[NSDictionary class]]) {
        RTCDataChannelConfiguration *init = [RTCDataChannelConfiguration new];

        if (json[@"id"]) {
            [init setChannelId:(int)[json[@"id"] integerValue]];
        }
        if (json[@"ordered"]) {
            init.isOrdered = [json[@"ordered"] boolValue];
        }
        if (json[@"maxRetransmits"]) {
            init.maxRetransmits = [json[@"maxRetransmits"] intValue];
        }
        if (json[@"negotiated"]) {
            init.isNegotiated = [json[@"negotiated"] boolValue];
        }
        if (json[@"protocol"]) {
            init.protocol = json[@"protocol"];
        }
        return init;
    }
    return nil;
}

- (CGRect)parseRect:(NSDictionary *)rect {
    return CGRectMake([[rect valueForKey:@"left"] doubleValue],
                      [[rect valueForKey:@"top"] doubleValue],
                      [[rect valueForKey:@"width"] doubleValue],
                      [[rect valueForKey:@"height"] doubleValue]);
}

- (NSDictionary*)dtmfSenderToMap:(id<RTCDtmfSender>)dtmf Id:(NSString*)Id {
     return @{
         @"dtmfSenderId": Id,
         @"interToneGap": @(dtmf.interToneGap / 1000.0),
         @"duration": @(dtmf.duration / 1000.0),
     };
}

- (NSDictionary*)rtpParametersToMap:(RTCRtpParameters*)parameters {
    NSDictionary *rtcp = @{
        @"cname": parameters.rtcp.cname,
        @"reducedSize": @(parameters.rtcp.isReducedSize),
    };
    
    NSMutableArray *headerExtensions = [NSMutableArray array];
    for (RTCRtpHeaderExtension* headerExtension in parameters.headerExtensions) {
        [headerExtensions addObject:@{
            @"uri": headerExtension.uri,
            @"encrypted": @(headerExtension.encrypted),
            @"id": @(headerExtension.id),
        }];
    }
    
    NSMutableArray *encodings = [NSMutableArray array];
    for (RTCRtpEncodingParameters* encoding in parameters.encodings) {
        [encodings addObject:@{
            @"active": @(encoding.isActive),
            @"minBitrateBps": encoding.minBitrateBps? encoding.minBitrateBps : [NSNumber numberWithInt:0],
            @"maxBitrateBps": encoding.maxBitrateBps? encoding.maxBitrateBps : [NSNumber numberWithInt:0],
            @"maxFramerate": encoding.maxFramerate? encoding.maxFramerate : @(30),
            @"numTemporalLayers": encoding.numTemporalLayers? encoding.numTemporalLayers : @(1),
            @"scaleResolutionDownBy": encoding.scaleResolutionDownBy? @(encoding.scaleResolutionDownBy.doubleValue) : [NSNumber numberWithDouble:1.0],
            @"ssrc": encoding.ssrc ? encoding.ssrc : [NSNumber numberWithLong:0]
        }];
    }

    NSMutableArray *codecs = [NSMutableArray array];
    for (RTCRtpCodecParameters* codec in parameters.codecs) {
        [codecs addObject:@{
            @"name": codec.name,
            @"payloadType": @(codec.payloadType),
            @"clockRate": codec.clockRate,
            @"numChannels": codec.numChannels? codec.numChannels : @(1),
            @"parameters": codec.parameters,
            @"kind": codec.kind
        }];
    }
    
     return @{
         @"transactionId": parameters.transactionId,
         @"rtcp": rtcp,
         @"headerExtensions": headerExtensions,
         @"encodings": encodings,
         @"codecs": codecs
     };
}

-(NSString*)streamTrackStateToString:(RTCMediaStreamTrackState)state {
    switch (state) {
        case RTCMediaStreamTrackStateLive:
            return @"live";
        case RTCMediaStreamTrackStateEnded:
            return @"ended";
        default:
            break;
    }
    return @"";
}

- (NSDictionary*)mediaStreamToMap:(RTCMediaStream *)stream ownerTag:(NSString*)ownerTag {
    NSMutableArray* audioTracks = [NSMutableArray array];
    NSMutableArray* videoTracks = [NSMutableArray array];
    
    for (RTCMediaStreamTrack* track in stream.audioTracks) {
        [audioTracks addObject:[self mediaTrackToMap:track]];
    }

    for (RTCMediaStreamTrack* track in stream.videoTracks) {
        [videoTracks addObject:[self mediaTrackToMap:track]];
    }

    return @{
        @"streamId": stream.streamId,
        @"ownerTag": ownerTag,
        @"audioTracks": audioTracks,
        @"videoTracks":videoTracks,
        
    };
}

- (NSDictionary*)mediaTrackToMap:(RTCMediaStreamTrack*)track {
    if(track == nil)
        return @{};
    NSDictionary *params = @{
        @"enabled": @(track.isEnabled),
        @"id": track.trackId,
        @"kind": track.kind,
        @"label": track.trackId,
        @"readyState": [self streamTrackStateToString:track.readyState],
        @"remote": @(YES)
        };
    return params;
}

- (NSDictionary*)rtpSenderToMap:(RTCRtpSender *)sender {
    NSDictionary *params = @{
        @"senderId": sender.senderId,
        @"ownsTrack": @(YES),
        @"rtpParameters": [self rtpParametersToMap:sender.parameters],
        @"track": [self mediaTrackToMap:sender.track],
        @"dtmfSender": [self dtmfSenderToMap:sender.dtmfSender Id:sender.senderId]
    };
    return params;
}

-(NSDictionary*)receiverToMap:(RTCRtpReceiver*)receiver {
    NSDictionary *params = @{
        @"receiverId": receiver.receiverId,
        @"rtpParameters": [self rtpParametersToMap:receiver.parameters],
        @"track": [self mediaTrackToMap:receiver.track],
    };
    return params;
}

-(RTCRtpTransceiver*) getRtpTransceiverById:(RTCPeerConnection *)peerConnection Id:(NSString*)Id {
    for( RTCRtpTransceiver* transceiver in peerConnection.transceivers) {
        if([transceiver.mid isEqualToString:Id]){
            return transceiver;
        }
    }
    return nil;
}

-(RTCRtpSender*) getRtpSenderById:(RTCPeerConnection *)peerConnection Id:(NSString*)Id {
   for( RTCRtpSender* sender in peerConnection.senders) {
       if([sender.senderId isEqualToString:Id]){
            return sender;
        }
    }
    return nil;
}

-(RTCRtpReceiver*) getRtpReceiverById:(RTCPeerConnection *)peerConnection Id:(NSString*)Id {
    for( RTCRtpReceiver* receiver in peerConnection.receivers) {
        if([receiver.receiverId isEqualToString:Id]){
            return receiver;
        }
    }
    return nil;
}

-(RTCRtpEncodingParameters*)mapToEncoding:(NSDictionary*)map {
    RTCRtpEncodingParameters *encoding = [[RTCRtpEncodingParameters alloc] init];
    encoding.isActive = YES;
    encoding.scaleResolutionDownBy = [NSNumber numberWithDouble:1.0];
    encoding.numTemporalLayers = [NSNumber numberWithInt:1];
#if TARGET_OS_IPHONE
    encoding.networkPriority = RTCPriorityLow;
    encoding.bitratePriority = 1.0;
#endif
    [encoding setRid:map[@"rid"]];
    
    if(map[@"active"] != nil) {
        [encoding setIsActive:((NSNumber*)map[@"active"]).boolValue];
    }
    
    if(map[@"minBitrateBps"] != nil) {
        [encoding setMinBitrateBps:(NSNumber*)map[@"minBitrateBps"]];
    }
    
    if(map[@"maxBitrateBps"] != nil) {
        [encoding setMaxBitrateBps:(NSNumber*)map[@"maxBitrateBps"]];
    }
    
    if(map[@"maxFramerate"] != nil) {
        [encoding setMaxFramerate:(NSNumber*)map[@"maxFramerate"]];
    }
    
    if(map[@"numTemporalLayers"] != nil) {
        [encoding setNumTemporalLayers:(NSNumber*)map[@"numTemporalLayers"]];
    }
    
    if(map[@"scaleResolutionDownBy"] != nil) {
        [encoding setScaleResolutionDownBy:(NSNumber*)map[@"scaleResolutionDownBy"]];
    }
    return  encoding;
}

-(RTCRtpTransceiverInit*)mapToTransceiverInit:(NSDictionary*)map {
    NSArray<NSString*>* streamIds = map[@"streamIds"];
    NSArray<NSDictionary*>* encodingsParams = map[@"sendEncodings"];
    NSString* direction = map[@"direction"];
    
    RTCRtpTransceiverInit* init = [RTCRtpTransceiverInit alloc];

    if(direction != nil) {
        init.direction = [self stringToTransceiverDirection:direction];
    }

    if(streamIds != nil) {
        init.streamIds = streamIds;
    }

    if(encodingsParams != nil) {
        NSArray<RTCRtpEncodingParameters *> *sendEncodings = [[NSArray alloc] init];
        for (NSDictionary* map in encodingsParams){
            sendEncodings = [sendEncodings arrayByAddingObject:[self mapToEncoding:map]];
        }
        [init setSendEncodings:sendEncodings];
    }
    return  init;
}

-(RTCRtpMediaType)stringToRtpMediaType:(NSString*)type {
    if([type isEqualToString:@"audio"]) {
        return RTCRtpMediaTypeAudio;
    } else if([type isEqualToString:@"video"]) {
        return RTCRtpMediaTypeVideo;
    } else if([type isEqualToString:@"data"]) {
        return RTCRtpMediaTypeData;
    }
    return RTCRtpMediaTypeAudio;
}

-(RTCRtpTransceiverDirection)stringToTransceiverDirection:(NSString*)type {
    if([type isEqualToString:@"sendrecv"]) {
            return RTCRtpTransceiverDirectionSendRecv;
    } else if([type isEqualToString:@"sendonly"]){
            return RTCRtpTransceiverDirectionSendOnly;
    } else if([type isEqualToString: @"recvonly"]){
            return RTCRtpTransceiverDirectionRecvOnly;
    } else if([type isEqualToString: @"inactive"]){
            return RTCRtpTransceiverDirectionInactive;
    }
    return RTCRtpTransceiverDirectionInactive;
}

-(RTCRtpParameters *)updateRtpParameters :(NSDictionary *)newParameters : (RTCRtpParameters *)parameters {
    NSArray* encodings = [newParameters objectForKey:@"encodings"];
    NSArray<RTCRtpEncodingParameters *> *nativeEncodings = parameters.encodings;
    for(int i = 0; i < [nativeEncodings count]; i++){
        RTCRtpEncodingParameters *nativeEncoding = [nativeEncodings objectAtIndex:i];
        NSDictionary *encoding = [encodings objectAtIndex:i];
        if([encoding objectForKey:@"active"]){
            nativeEncoding.isActive =  [(NSNumber *)[encoding objectForKey:@"active"] boolValue];
        }
        if([encoding objectForKey:@"maxBitrateBps"]){
            nativeEncoding.maxBitrateBps =  [encoding objectForKey:@"maxBitrateBps"];
        }
        if([encoding objectForKey:@"minBitrateBps"]){
            nativeEncoding.minBitrateBps =  [encoding objectForKey:@"minBitrateBps"];
        }
        if([encoding objectForKey:@"maxFramerate"]){
            nativeEncoding.maxFramerate =  [encoding objectForKey:@"maxFramerate"];
        }
        if([encoding objectForKey:@"numTemporalLayers"]){
            nativeEncoding.isActive =  [(NSNumber *)[encoding objectForKey:@"numTemporalLayers"] boolValue];
        }
        if([encoding objectForKey:@"scaleResolutionDownBy"]){
            nativeEncoding.scaleResolutionDownBy =  [encoding objectForKey:@"scaleResolutionDownBy"];
        }
    }

    return parameters;
  }

-(NSString*)transceiverDirectionString:(RTCRtpTransceiverDirection)direction {
       switch (direction) {
        case RTCRtpTransceiverDirectionSendRecv:
            return @"sendrecv";
        case RTCRtpTransceiverDirectionSendOnly:
            return @"sendonly";
        case RTCRtpTransceiverDirectionRecvOnly:
            return @"recvonly";
        case RTCRtpTransceiverDirectionInactive:
            return @"inactive";
#if TARGET_OS_IPHONE
        case RTCRtpTransceiverDirectionStopped:
            return @"stopped";
#endif
               break;
       }
    return nil;
}

-(NSDictionary*)transceiverToMap:(RTCRtpTransceiver*)transceiver {
    NSString* mid = transceiver.mid? transceiver.mid : @"";
    NSDictionary* params = @{
        @"transceiverId": mid,
        @"mid": mid,
        @"direction": [self transceiverDirectionString:transceiver.direction],
        @"sender": [self rtpSenderToMap:transceiver.sender],
        @"receiver": [self receiverToMap:transceiver.receiver]
    };
    return params;
}

- (void)addCameraListener:(id<CameraSwitchObserver>)observer {
    dispatch_async(_dispatchQueue, ^() {
        [self->_cameraListeners addObject:observer];
    });
}

- (void)removeCameraListener:(id<CameraSwitchObserver>)observer {
    // You can't use strong or weak pointers if the observer is already in the dealloc phase (i.e. removeObserver:
    // is called from the observer's dealloc method). It will cause a crash.
    id __unsafe_unretained unretainedObserver = observer;
    dispatch_async(_dispatchQueue, ^() {
        [self->_cameraListeners removeObject:unretainedObserver];
    });
}

- (BOOL)containsObserver:(id<CameraSwitchObserver>)observer {
    BOOL __block result;
    dispatch_sync(_dispatchQueue, ^() {
        result = [self->_cameraListeners containsObject:observer];
    });
    return result;
}

@end
