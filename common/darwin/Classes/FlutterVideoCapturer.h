#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN


typedef void (^OnSuccess)(void);
typedef void (^OnError)(NSString *errorType, NSString *errorMessage);

@protocol FlutterVideoCapturer <NSObject>

@property(readonly, atomic) BOOL facing;

- (void)startCapture:(nullable OnSuccess)success onError: (nullable OnError)error;
- (void)stopCapture:(nullable  OnSuccess)success onError: (nullable  OnError)error;
- (void)switchCamera:(nullable  OnSuccess)success onError: (nullable OnError)error;
- (void)restartCapture:(nullable OnSuccess)success onError: (nullable OnError)onError;
- (void)stopRunning:(nullable OnSuccess)success onError: (nullable OnError)onError;
- (void)startRunning:(nullable OnSuccess)success onError: (nullable OnError)onError;

@end

@protocol CameraSwitchObserver <NSObject>

- (void)willSwitchCamera:(bool)isFacing trackId: (NSString*)trackid;
- (void)didSwitchCamera:(bool)isFacing trackId: (NSString*)trackid;
- (void)didFailSwitch:(NSString*)trackid;
@end


NS_ASSUME_NONNULL_END
