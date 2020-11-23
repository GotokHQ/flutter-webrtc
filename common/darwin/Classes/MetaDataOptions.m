//
//  MediaRecorder.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 1/23/19.
//

#import "MetaDataOptions.h"

@implementation MetaDataOptions

- (instancetype)initWithThumbnailWidth:(NSInteger)thumbnailWidth thumbnailHeight:(NSInteger)thumbnailHeight thumbnailQuality:(float)thumbnailQuality audioOnly:(BOOL)audioOnly{
    self = [super init];
    _thumbnailWidth = thumbnailWidth;
    _thumbnailHeight = thumbnailHeight;
    _thumbnailQuality = thumbnailQuality;
    _audioOnly = audioOnly;
    return self;
}

@end
