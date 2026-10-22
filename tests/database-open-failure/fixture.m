#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <stdatomic.h>
#include <assert.h>
#include <unistd.h>

#define Log(...) ((void)0)
static atomic_int openAttempts;
static atomic_bool failOpen;
static atomic_bool slowOpen;

@interface ProbeCoordinator : NSPersistentStoreCoordinator @end
@implementation ProbeCoordinator
- (NSPersistentStore *)addPersistentStoreWithType:(NSString *)type configuration:(NSString *)configuration URL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error {
    atomic_fetch_add(&openAttempts, 1);
    if (atomic_load(&slowOpen)) usleep(20000);
    if (atomic_load(&failOpen)) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
        return nil;
    }
    return [super addPersistentStoreWithType:type configuration:configuration URL:url options:options error:error];
}
@end

#define NSPersistentStoreCoordinator ProbeCoordinator
/* PRODUCTION_SINGLETON */
#undef NSPersistentStoreCoordinator

@interface FixtureDatabase : DatabaseSingleton
@property(nonatomic, strong) NSURL *fixtureURL;
@property(nonatomic, strong) NSManagedObjectModel *fixtureModel;
@end
static FixtureDatabase *activeDatabase;
@implementation FixtureDatabase
+ (DatabaseSingleton *)shared { return activeDatabase; }
- (NSURL *)getStoreURL { return self.fixtureURL; }
- (NSManagedObjectModel *)managedObjectModel { return self.fixtureModel; }
@end

@interface Settings : NSManagedObject
@property(nonatomic, copy) NSString *uniqueId;
@end
@implementation Settings
@dynamic uniqueId;
@end
#define Host NSManagedObject
@interface TemporaryHost : NSObject
@property(nonatomic, copy) NSString *name;
- (instancetype)initFromHost:(NSManagedObject *)host;
@end
@implementation TemporaryHost
- (instancetype)initFromHost:(NSManagedObject *)host {
    self = [super init];
    if (self) _name = [host valueForKey:@"name"];
    return self;
}
@end

@interface TemporarySettings : NSObject
- (instancetype)initFromSettings:(Settings *)settings;
@end
@implementation TemporarySettings
- (instancetype)initFromSettings:(Settings *)settings { return [super init]; }
@end

@interface DataManager : NSObject {
    NSManagedObjectContext *_managedObjectContext;
}
@property(nonatomic, readonly, getter=isAvailable) BOOL available;
- (NSManagedObjectContext *)databaseContext;
- (void)updateUniqueId:(NSString *)uniqueId;
- (NSString *)getUniqueId;
- (Settings *)retrieveSettings;
- (NSArray *)fetchRecords:(NSString *)entity;
- (NSArray *)getHosts;
- (TemporarySettings *)getSettings;
- (void)saveData;
@end
@implementation DataManager
/* PRODUCTION_DATA_MANAGER */
@end

static int generatedIdentities;
@interface IdentityGenerator : NSObject
+ (NSString *)generateUniqueId;
@end
@implementation IdentityGenerator
+ (NSString *)generateUniqueId { generatedIdentities++; return @"fixture-new-client"; }
@end
@interface IdManager : NSObject
+ (NSString *)getUniqueId;
@end
@implementation IdManager
/* PRODUCTION_IDENTITY */
@end

static NSAttributeDescription *attribute(NSString *name, NSAttributeType type) {
    NSAttributeDescription *value = [NSAttributeDescription new];
    value.name = name;
    value.attributeType = type;
    value.optional = NO;
    return value;
}
static NSManagedObjectModel *model(BOOL incompatible) {
    NSEntityDescription *host = [NSEntityDescription new];
    host.name = @"Host";
    host.managedObjectClassName = @"NSManagedObject";
    host.properties = incompatible
        ? @[attribute(@"name", NSStringAttributeType), attribute(@"requiredNewField", NSUUIDAttributeType)]
        : @[attribute(@"name", NSStringAttributeType)];
    NSEntityDescription *settings = [NSEntityDescription new];
    settings.name = @"Settings";
    settings.managedObjectClassName = @"Settings";
    settings.properties = @[attribute(@"uniqueId", NSStringAttributeType)];
    NSManagedObjectModel *result = [NSManagedObjectModel new];
    result.entities = @[host, settings];
    return result;
}
static FixtureDatabase *database(NSURL *url, NSManagedObjectModel *schema) {
    FixtureDatabase *db = [FixtureDatabase new];
    db.fixtureURL = url;
    db.fixtureModel = schema;
    return db;
}
static NSURL *testURL(NSURL *root, NSString *name) {
    return [root URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"sqlite"]];
}
static void closeDatabase(FixtureDatabase *db) {
    NSManagedObjectContext *context = [db valueForKey:@"_managedObjectContext"];
    [context performBlockAndWait:^{ [context reset]; }];
    NSPersistentStoreCoordinator *coordinator = [db valueForKey:@"_persistentStoreCoordinator"];
    for (NSPersistentStore *store in coordinator.persistentStores.copy) {
        NSError *error = nil;
        assert([coordinator removePersistentStore:store error:&error]);
    }
}
static void testPreservation(NSURL *root) {
    NSURL *url = testURL(root, @"injected-failure");
    NSMutableDictionary<NSString *, NSData *> *originals = [NSMutableDictionary dictionary];
    for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
        NSString *path = [url.path stringByAppendingString:suffix];
        NSData *bytes = [[@"fixture original bytes: " stringByAppendingString:suffix] dataUsingEncoding:NSUTF8StringEncoding];
        assert([bytes writeToFile:path atomically:NO]);
        originals[path] = bytes;
    }
    atomic_store(&failOpen, true);
    atomic_store(&openAttempts, 0);
    FixtureDatabase *db = database(url, model(NO));
    assert(db.persistentStoreCoordinator == nil);
    assert(db.managedObjectContext == nil);
    assert(atomic_load(&openAttempts) == 2);
    for (NSString *path in originals) assert([[NSData dataWithContentsOfFile:path] isEqualToData:originals[path]]);
    puts("PASS: failed attachment preserves SQLite, WAL and SHM byte-for-byte and never caches an empty coordinator");
}
static void testMissingModel(NSURL *root) {
    atomic_store(&openAttempts, 0);
    FixtureDatabase *db = database(testURL(root, @"missing-model"), nil);
    assert(db.persistentStoreCoordinator == nil);
    assert(db.managedObjectContext == nil);
    assert(atomic_load(&openAttempts) == 0);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:db.fixtureURL.path]);
    puts("PASS: a missing model does not create a coordinator or a replacement store");
}
static void testRetryAndConcurrency(NSURL *root) {
    atomic_store(&failOpen, true);
    atomic_store(&openAttempts, 0);
    FixtureDatabase *db = database(testURL(root, @"retry"), model(NO));
    assert(db.persistentStoreCoordinator == nil);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:db.fixtureURL.path]);
    atomic_store(&failOpen, false);
    atomic_store(&slowOpen, true);
    NSMutableSet *coordinators = [NSMutableSet set];
    NSMutableSet *contexts = [NSMutableSet set];
    dispatch_apply(24, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        NSPersistentStoreCoordinator *coordinator = db.persistentStoreCoordinator;
        NSManagedObjectContext *context = db.managedObjectContext;
        assert(coordinator.persistentStores.count == 1);
        assert(context.persistentStoreCoordinator == coordinator);
        @synchronized(coordinators) {
            [coordinators addObject:coordinator];
            [contexts addObject:context];
        }
    });
    atomic_store(&slowOpen, false);
    assert(coordinators.count == 1 && contexts.count == 1);
    assert(atomic_load(&openAttempts) == 2);
    NSManagedObjectContext *context = db.managedObjectContext;
    [context performBlockAndWait:^{
        NSManagedObject *host = [NSEntityDescription insertNewObjectForEntityForName:@"Host" inManagedObjectContext:context];
        [host setValue:@"existing host" forKey:@"name"];
    }];
    [db saveContext];
    closeDatabase(db);
    puts("PASS: retry attaches a real store; concurrent callers receive one coordinator/context; private-queue save succeeds");
}
static void testIncompatibleModel(NSURL *root) {
    NSURL *url = testURL(root, @"retry");
    FixtureDatabase *wrong = database(url, model(YES));
    assert(wrong.persistentStoreCoordinator == nil);
    assert([[NSFileManager defaultManager] fileExistsAtPath:url.path]);
    FixtureDatabase *correct = database(url, model(NO));
    NSManagedObjectContext *context = correct.managedObjectContext;
    assert(context != nil);
    [context performBlockAndWait:^{
        NSError *error = nil;
        NSArray *hosts = [context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Host"] error:&error];
        assert(error == nil && hosts.count == 1);
        assert([[hosts.firstObject valueForKey:@"name"] isEqualToString:@"existing host"]);
    }];
    closeDatabase(correct);
    puts("PASS: an incompatible-model migration failure leaves the existing host readable with its original model");
}
static void testDataManagerAndIdentity(NSURL *root) {
    atomic_store(&failOpen, true);
    activeDatabase = database(testURL(root, @"data-manager"), model(NO));
    DataManager *manager = [DataManager new];
    assert(manager != nil);
    assert(!manager.isAvailable);
    assert(manager.databaseContext == nil);
    assert(manager.getHosts.count == 0);
    assert(manager.getUniqueId == nil);
    assert(manager.getSettings == nil);
    [manager updateUniqueId:@"must not be persisted"];
    generatedIdentities = 0;
    assert([IdManager getUniqueId] == nil);
    assert([IdManager getUniqueId] == nil);
    assert(generatedIdentities == 0);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:activeDatabase.fixtureURL.path]);
    atomic_store(&failOpen, false);
    assert(manager.isAvailable);
    assert(manager.databaseContext.persistentStoreCoordinator.persistentStores.count == 1);
    assert([[IdManager getUniqueId] isEqualToString:@"fixture-new-client"]);
    assert([[IdManager getUniqueId] isEqualToString:@"fixture-new-client"]);
    assert(generatedIdentities == 1);
    assert([[manager getUniqueId] isEqualToString:@"fixture-new-client"]);
    closeDatabase(activeDatabase);
    activeDatabase = nil;
    puts("PASS: DataManager skips unavailable stores, retries on the same instance and never invents a transient client identity");
}
int main(void) { @autoreleasepool {
    const char *directory = getenv("MOONLIGHT_DATABASE_TEST_DIR");
    assert(directory != NULL);
    NSURL *root = [[NSURL fileURLWithPath:[NSString stringWithUTF8String:directory] isDirectory:YES] URLByAppendingPathComponent:@"stores" isDirectory:YES];
    assert([[NSFileManager defaultManager] createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL]);
    testPreservation(root);
    testMissingModel(root);
    testRetryAndConcurrency(root);
    testIncompatibleModel(root);
    testDataManagerAndIdentity(root);
    assert([[NSFileManager defaultManager] removeItemAtURL:root error:NULL]);
} }
