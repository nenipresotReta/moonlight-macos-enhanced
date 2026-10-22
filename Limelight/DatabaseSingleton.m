//
//  DatabaseSingleton.m
//  Moonlight
//
//  Created by Michael Kenny on 10/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import "DatabaseSingleton.h"

@interface DatabaseSingleton ()
@property (strong, nonatomic) NSManagedObjectContext *managedObjectContext;
@property (strong, nonatomic) NSManagedObjectModel *managedObjectModel;
@property (strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@end

@implementation DatabaseSingleton

+ (DatabaseSingleton *)shared {
    static DatabaseSingleton *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DatabaseSingleton alloc] init];
    });
    
    return instance;
}

- (void)saveContext
{
    NSManagedObjectContext *context = self.managedObjectContext;
    [context performBlockAndWait:^{
        NSError *error = nil;
        if ([context hasChanges] && ![context save:&error]) {
            Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);
        }
    }];
}

// Publish each lazy object only after it is ready. Discovery and UI callers can
// request the database concurrently, including after a failed open.
- (NSManagedObjectContext *)managedObjectContext
{
    @synchronized (self) {
        if (_managedObjectContext != nil) {
            return _managedObjectContext;
        }

        NSPersistentStoreCoordinator *coordinator = self.persistentStoreCoordinator;
        if (coordinator == nil) {
            return nil;
        }

        NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        context.persistentStoreCoordinator = coordinator;
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
        _managedObjectContext = context;
        return _managedObjectContext;
    }
}

- (NSManagedObjectModel *)managedObjectModel
{
    @synchronized (self) {
        if (_managedObjectModel == nil) {
            _managedObjectModel = [NSManagedObjectModel mergedModelFromBundles:nil];
        }
        return _managedObjectModel;
    }
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    @synchronized (self) {
        if (_persistentStoreCoordinator != nil) {
            return _persistentStoreCoordinator;
        }

        NSManagedObjectModel *model = self.managedObjectModel;
        if (model == nil) {
            Log(LOG_E, @"Unable to open database: the managed object model is unavailable");
            return nil;
        }

        NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        NSDictionary *options = @{
            NSMigratePersistentStoresAutomaticallyOption: @YES,
            NSInferMappingModelAutomaticallyOption: @YES
        };
        NSError *error = nil;
        if (![coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                      configuration:nil
                                                URL:[self getStoreURL]
                                            options:options
                                              error:&error]) {
            // An incompatible model, permissions, a locked store, or a temporary
            // I/O failure must never erase the user's database or its sidecars.
            // Leave the cache empty so a later request makes a real open attempt.
            Log(LOG_E, @"Unable to open database; existing data was preserved: %@, %@", error, error.userInfo);
            return nil;
        }

        _persistentStoreCoordinator = coordinator;
        return _persistentStoreCoordinator;
    }
}


#pragma mark - Database Path

+ (NSURL *)applicationSupportDirectory {
    
    NSURL *directoryUrl = [[[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject]
            URLByAppendingPathComponent:@"Moonlight"];
    NSError *error;
    if (![[NSFileManager defaultManager] fileExistsAtPath:directoryUrl.path]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:directoryUrl.path withIntermediateDirectories:YES attributes:nil error:&error];
    }
    
    return directoryUrl;
}

- (NSURL *)getStoreURL {
    return [[DatabaseSingleton applicationSupportDirectory] URLByAppendingPathComponent:@"Moonlight_macOS.sqlite"];
}

@end
