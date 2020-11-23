//
//  FlutterAudioMixer.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 9/1/19.
//

#import "FlutterAudioMixer.h"
#include <mach/mach_time.h>

#define TIME_UNIT NSEC_PER_SEC

static NSString* const kAudioMixerErrorDomain = @"AudioMixer";
static NSInteger const kRenderError = -1;
static NSInteger const kBufferError = -2;

@implementation FlutterAudioMixer {
    NSMutableArray<id<SamplesInterceptorDelegate>> *_interceptors;
    dispatch_queue_t _audioQueue;
    BOOL _admStarted;
    BOOL _running;
    uint64_t _totalSamplesNum;
    CMTime  _audioStartTime;
    dispatch_semaphore_t _audio_semaphore;
}

- (dispatch_queue_t)audioQueue {
    if (!_audioQueue) {
        _audioQueue = dispatch_queue_create("cloudwebrtc.com/WebRTC.Audio.Queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_audioQueue,
                                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    }
    return _audioQueue;
}

-(instancetype)init{
    if (self = [super init]) {
        _adm = [[RCAudioDeviceModule alloc] initWithDelegate:self];
        _interceptors = [[NSMutableArray alloc] init];
        _audioStartTime = kCMTimeInvalid;
        _audio_semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)startCapture{
    if (_running) {
        return;
    }
    _running = YES;
}

-(void)stopCapture{
    if (!_running) {
        return;
    }
    _running = NO;
}

- (void)dealloc{
    [self cleanup];
}

- (void)cleanup
{
    if(_adm && _admStarted){
        [_adm stopMixing];
        _admStarted = NO;
    }
    [_interceptors removeAllObjects];
}

-(void)maybeStartCapture{
    if([_adm isInitialized]){
        [self startAudioCapture];
    }
}

- (void)startAudioCapture;
{
    if(_admStarted || !_adm || ![_adm isInitialized]){
        return;
    }
    int32_t ret = [_adm startMixing];
    NSLog(@"STARTED MIXING:%d",ret);
    if (ret != 0) {
        NSLog(@"Start Mixing Failed:%d",ret);
        NSDictionary *userInfo = @{
                                   NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to start audio mixer. Error=%ld", (long)ret],
                                   };
        NSError *renderError =
        [[NSError alloc] initWithDomain:kAudioMixerErrorDomain
                                   code:kRenderError
                               userInfo:userInfo];
        [self didAudioCaptureFailWithError:renderError];
        return;
    }
    __weak FlutterAudioMixer *weakSelf = self;
    dispatch_async([self audioQueue], ^{
        FlutterAudioMixer *strongSelf = weakSelf;
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp inTimeStamp;
        memset(&inTimeStamp, 0, sizeof(AudioTimeStamp));
        inTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
        UInt32 busNumber = 0;
        UInt32 numberFrames = [strongSelf->_adm framesPerBuffer];
        inTimeStamp.mSampleTime = 0;
        int channelCount = [strongSelf->_adm numberOfChannels];
        
        AudioBufferList *bufferList = [self pollAudioBuffer:numberFrames
                                                   channels:channelCount
                                             bytesPerSample:[strongSelf->_adm bytesPerSample]];
        
        while(strongSelf->_admStarted){
            //            if(CMTIME_IS_INVALID(strongSelf->_audioStartTime)) {
            //                usleep(100000);
            //                NSLog(@"Waiting for media to be ready");
            //                continue;
            //            }
            dispatch_semaphore_wait(strongSelf->_audio_semaphore, DISPATCH_TIME_FOREVER);
            
            if(!strongSelf->_admStarted){
                break;
            }
            
            [self captureAudioSamples:&flags
                            timeStamp:&inTimeStamp
                            busNumber:busNumber
                         numberFrames:numberFrames
                               iodata:bufferList
             ];
        }
        NSLog(@"Audio Capture ended");
    });
    
    
}
-(AudioBufferList*)pollAudioBuffer:(UInt32)numberFrames channels:(int)channelCount bytesPerSample:(int)bytesPerSample{
    AudioBufferList *bufferList = (AudioBufferList*)malloc(sizeof(AudioBufferList)+sizeof(AudioBuffer)*(channelCount-1));
    bufferList->mNumberBuffers = channelCount;
    for (int j=0; j<channelCount; j++)
    {
        AudioBuffer buffer = {0};
        buffer.mNumberChannels = 1;
        buffer.mDataByteSize = (int)numberFrames*bytesPerSample;
        buffer.mData = calloc(numberFrames, bytesPerSample);
        bufferList->mBuffers[j] = buffer;
        
    }
    return bufferList;
}

- (void) captureAudioSamples:(AudioUnitRenderActionFlags *)flags
                   timeStamp:(AudioTimeStamp *) timeStamp
                   busNumber:(UInt32)busNumber
                numberFrames:(UInt32) numberFrames
                      iodata:(AudioBufferList*) iodata
{
    
    @autoreleasepool {
        
        OSStatus result = [_adm render:flags
                             timeStamp:timeStamp
                             busNumber:busNumber
                             numFrames:numberFrames
                                ioData:iodata
                           ];
        if (result != noErr) {
            NSLog(@"Failed to render audio unit. Error=%ld", (long)result);
            NSDictionary *userInfo = @{
                                       NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to render audio unit. Error=%ld", (long)result],
                                       };
            NSError *renderError =
            [[NSError alloc] initWithDomain:kAudioMixerErrorDomain
                                       code:kRenderError
                                   userInfo:userInfo];
            [self didAudioCaptureFailWithError:renderError];
            return;
        }
        
        AudioStreamBasicDescription monoStreamFormat = [_adm GetMixerFormat];
        
        CMFormatDescriptionRef format = NULL;
        OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &monoStreamFormat, 0, NULL, 0, NULL, NULL, &format);
        if (status != noErr) {
            // really shouldn't happen
            return;
        }
        
        
        NSTimeInterval timeStampSeconds = CACurrentMediaTime();
        int64_t timeStamp = timeStampSeconds * TIME_UNIT;
        CMTime presentationTime = CMTimeMake(timeStamp, TIME_UNIT);
        
        if (CMTIME_IS_INVALID(_audioStartTime))
        {
            _audioStartTime = presentationTime;
        }
        
        presentationTime = [self jitterFreePTS:timeStamp samples:numberFrames sampleRate:monoStreamFormat.mSampleRate];
        
        CMSampleTimingInfo timing = { CMTimeMake(1, monoStreamFormat.mSampleRate), presentationTime, kCMTimeInvalid };
        
        CMSampleBufferRef sampleBuffer = NULL;
        
        status = CMSampleBufferCreate(kCFAllocatorDefault, NULL, false, NULL, NULL, format, numberFrames, 1, &timing, 0, NULL, &sampleBuffer);
        if (status != noErr) {
            // couldn't create the sample buffer
            NSLog(@"Failed to create sample buffer");
            NSDictionary *userInfo = @{
                                       NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create sample buffer. Error=%ld", (long)status],
                                       };
            NSError *bufferError = [[NSError alloc] initWithDomain:kAudioMixerErrorDomain
                                                              code:kBufferError
                                                          userInfo:userInfo];
            [self didAudioCaptureFailWithError:bufferError];
            CFRelease(format);
            return;
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer,
                                                                kCFAllocatorDefault,
                                                                kCFAllocatorDefault,
                                                                0,
                                                                iodata);
        if (status != noErr) {
            // couldn't create the sample buffer
            NSLog(@"Failed to create sample buffer from buffer list");
            NSDictionary *userInfo = @{
                                       NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create sample buffer. Error=%ld", (long)status],
                                       };
            NSError *bufferError = [[NSError alloc] initWithDomain:kAudioMixerErrorDomain
                                                              code:kBufferError
                                                          userInfo:userInfo];
            [self didAudioCaptureFailWithError:bufferError];
            CFRelease(format);
            CFRelease(sampleBuffer);
            return;
        }
        
        [self didCaptureAudioSamples:sampleBuffer];
        
        CFRelease(format);
        CFRelease(sampleBuffer);
    }
    
}

-(CMTime)jitterFreePTS:(uint64_t)bufferPts samples:(uint64_t)bufferSamplesNum sampleRate:(int)sampleRate{
    uint64_t correctedPts = 0;
    uint64_t bufferDuration = (TIME_UNIT * bufferSamplesNum) / (sampleRate);
    bufferPts = bufferPts - bufferDuration;
    if (_totalSamplesNum == 0) {
        // reset
        _audioStartTime = CMTimeMake(bufferPts,TIME_UNIT);
        _totalSamplesNum = 0;
    }
    
    correctedPts = CMTimeGetSeconds(_audioStartTime)-((TIME_UNIT * _totalSamplesNum) / (sampleRate));
    if(bufferPts - correctedPts >= 2*bufferDuration) {
        // reset
        _audioStartTime = CMTimeMake(bufferPts,TIME_UNIT);
        _totalSamplesNum = 0;
        correctedPts = bufferPts;
    }
    _totalSamplesNum += bufferSamplesNum;
    return CMTimeMake(correctedPts,TIME_UNIT);
}


-(void)addAudioSamplesInterceptor:(id<SamplesInterceptorDelegate>)interceptor{
    NSUInteger index = [_interceptors indexOfObjectIdenticalTo:interceptor];
    if (index == NSNotFound) {
        [_interceptors addObject:interceptor];
    }
}

-(void)removeAudioSamplesInterceptor:(id<SamplesInterceptorDelegate>)interceptor{
    NSUInteger index = [_interceptors indexOfObjectIdenticalTo:interceptor];
    if (index != NSNotFound) {
        [_interceptors removeObjectAtIndex:index];
    }
}

- (void)didCaptureAudioSamples:(CMSampleBufferRef)audioSample {
    for (id interceptor in _interceptors) {
        [interceptor didCaptureAudioSamples:audioSample];
    }
}

- (void)didAudioCaptureFailWithError:(NSError*)error {
    for (id interceptor in _interceptors) {
        [interceptor didAudioCaptureFailWithError:error];
    }
}

#pragma "RTCAudioMixerObserver Delegate"

-(void)OnAudioInitialized{
    NSLog(@"On OnAudioInitialized");
    [self maybeStartCapture];
}

-(void)onDataAvailable{
    //NSLog(@"On Data Available");
    dispatch_semaphore_signal(_audio_semaphore);
}

-(void)handleInterruptionBegin{
    NSLog(@"INTERRUPTION BEGIN. MAYBE PAUSE");
}

-(void)handleInterruptionEnd{
    NSLog(@"INTERRUPTION END. MAYBE RESUE");
}

-(void)handleInterruptionFailed{
    
    NSLog(@"INTERRUPTION FAILED. STOP ");
}

-(void)onStarted{
    NSLog(@"AUDIO MIXER STARTED CALLBACK");
    _admStarted = YES;
}

-(void)onStopped{
    NSLog(@"AUDIO MIXER STOPPED CALLBACK");
    _admStarted = NO;
    dispatch_semaphore_signal(_audio_semaphore);
    [self cleanup];
    //
}

- (void)onShutDown {
    NSLog(@"AUDIO MIXER SHUT DOWN CALLED ON VIDEO COMPOSER");
    _admStarted = NO;
}
@end
