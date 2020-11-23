//
//  NSError+FlutterError.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 1/24/19.
//

#import "NSError+FlutterError.h"

@implementation NSError (FlutterError)
- (FlutterError *)flutterError {
    return [FlutterError errorWithCode:[NSString stringWithFormat:@"Error %d", (int)self.code]
                               message:self.domain
                               details:self.localizedDescription];
}
@end
