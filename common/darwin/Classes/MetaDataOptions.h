#import <Foundation/Foundation.h>

@interface MetaDataOptions : NSObject
@property(readonly, nonatomic) NSInteger thumbnailWidth;
@property(readonly, nonatomic) NSInteger thumbnailHeight;
@property(readonly, nonatomic) float thumbnailQuality;
@property(readonly, nonatomic) bool audioOnly;

- (instancetype)initWithThumbnailWidth:(NSInteger)thumbnailWidth thumbnailHeight:(NSInteger)thumbnailHeight thumbnailQuality:(float)thumbnailQuality audioOnly:(BOOL)audioOnly;
@end
