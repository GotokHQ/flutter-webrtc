//
//  NSError+FlutterError.h
//  Pods
//
//  Created by Onyemaechi Okafor on 1/24/19.
//
#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>

@interface NSError (FlutterError)
    @property(readonly, nonatomic) FlutterError *flutterError;
@end
