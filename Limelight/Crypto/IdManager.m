//
//  IdManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/31/15.
//  Copyright © 2015 Moonlight Stream. All rights reserved.
//

#import "IdManager.h"
#import "DataManager.h"

@implementation IdManager

+ (NSString*) getUniqueId {
    DataManager* dataMan = [[DataManager alloc] init];

    if (!dataMan.isAvailable) {
        Log(LOG_E, @"Client identity unavailable because the database could not be opened");
        return nil;
    }

    NSString* uniqueId = [dataMan getUniqueId];
    if (uniqueId == nil) {
        uniqueId = [IdManager generateUniqueId];
        [dataMan updateUniqueId:uniqueId];
        Log(LOG_I, @"No UUID found. Generated new UUID: %@", uniqueId);
    }
    
    return uniqueId;
}

+ (NSString*) generateUniqueId {
    UInt64 uuidLong = ((UInt64) arc4random() << 32) | arc4random();
    return [NSString stringWithFormat:@"%016llx", uuidLong];
}

@end
