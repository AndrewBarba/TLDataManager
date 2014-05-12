//
//  TLDataManager.m
//  Tablelist
//
//  Created by Andrew Barba on 3/28/14.
//  Copyright (c) 2014 Tablelist, Inc. All rights reserved.
//

#import "TLDataManager.h"

// static constants
static NSString   *TLDatabaseName      = @"TLCoreDataDatabase";
static NSString   *TLDatabaseModelName = @"Model";
static double      TLSaveInterval      = 10.0;

@interface TLDataManager() {
    
    // store
    NSPersistentStoreCoordinator *_persistentStoreCoordinator;
    NSPersistentStore *_persistentStore;
    
    // model
    NSManagedObjectModel *_managedObjectModel;
    
    // contexts
    NSManagedObjectContext *_masterContext;
    NSManagedObjectContext *_mainContext;
    NSManagedObjectContext *_backgroundContext;
    
    // vars
    NSString *_databaseName;
    NSString *_modelName;
    NSDate *_lastSave;
    NSInteger _saveInterval;
    NSUInteger _activeOperations;
    BOOL _isSaving;
}

@end

@implementation TLDataManager

+ (void)setDatabaseName:(NSString *)databaseName linkedToModel:(NSString *)modelName
{
    TLDatabaseName = databaseName;
    TLDatabaseModelName = modelName;
}

#pragma mark - Persistent Store

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (!_persistentStoreCoordinator) {
        NSURL *storeURL = [self persistentStoreURL];
        NSDictionary *options = [self persistentStoreOptions];
        _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
        _persistentStore = [_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                     configuration:nil
                                                                               URL:storeURL
                                                                           options:options
                                                                             error:nil];
    };
    return _persistentStoreCoordinator;
}

- (NSURL *)persistentStoreURL
{
    NSString *name = [_databaseName copy];
    if ([name rangeOfString:@".sqlite"].location == NSNotFound) {
        name = [name stringByAppendingString:@".sqlite"];
    }
    NSURL *documentDirectory = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [documentDirectory URLByAppendingPathComponent:name];
}

- (NSDictionary *)persistentStoreOptions
{
    return @{ NSMigratePersistentStoresAutomaticallyOption : @(YES),
              NSInferMappingModelAutomaticallyOption       : @(YES) };
}

#pragma mark - Object Model

- (NSManagedObjectModel *)managedObjectModel
{
    if (!_managedObjectModel) {
        NSString *modelName = [_modelName copy];
        NSURL *modelURL = [[NSBundle mainBundle] URLForResource:modelName withExtension:@"momd"];
        _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    };
    return _managedObjectModel;
}

#pragma mark - Contexts

- (NSManagedObjectContext *)masterContext
{
    if (!_masterContext) {
        _masterContext = [[self class] contextWithConcurrencyType:NSPrivateQueueConcurrencyType
                                                    parentContext:nil
                                                      undoManager:nil];
        [_masterContext setPersistentStoreCoordinator:[self persistentStoreCoordinator]];
    };
    return _masterContext;
}

- (NSManagedObjectContext *)mainContext
{
    if (!_mainContext) {
        _mainContext = [[self class] contextWithConcurrencyType:NSMainQueueConcurrencyType
                                                  parentContext:[self masterContext]
                                                    undoManager:nil];
    };
    return _mainContext;
}

- (NSManagedObjectContext *)backgroundContext
{
    if (!_backgroundContext) {
        _backgroundContext = [[self class] contextWithConcurrencyType:NSPrivateQueueConcurrencyType
                                                        parentContext:[self mainContext]
                                                          undoManager:nil];
    }
    return _backgroundContext;
}

+ (NSManagedObjectContext *)contextWithConcurrencyType:(NSManagedObjectContextConcurrencyType)concurrencyType
                                         parentContext:(NSManagedObjectContext *)parentContext
                                           undoManager:(NSUndoManager *)undoManager
{
    NSManagedObjectContext *_context = [[NSManagedObjectContext alloc] initWithConcurrencyType:concurrencyType];
    if (parentContext) {
        _context.parentContext = parentContext;
    }
    [_context setUndoManager:undoManager];
    return _context;
}

#pragma mark - Importing

- (void)importData:(TLImportBlock)importBlock
{
    _activeOperations++;
    
    NSManagedObjectContext *context = [self backgroundContext];
    
    [context performBlock:^{
        
        // peform the import, copy return block to be called when done
        TLBlock complete = importBlock(context);
        
        // save the background context and propagate changes up to the main context
        [context save:nil];
        
        // call the completion block from the main context
        [self.mainContext performBlockAndWait:^{
            if (complete) {
                complete();
            }
            
            // decrease active ops
            _activeOperations--;
            
            // are all operations finished
            if (_activeOperations == 0) {
                
                // ditch the background context
                _backgroundContext = nil;
                
                // save to disk if needed
                if (_saveInterval < fabs([_lastSave timeIntervalSinceNow])) {
                    [self save];
                }
            }
        }];
    }];
}

- (NSUInteger)activeOperations
{
    return _activeOperations;
}

- (BOOL)isImportingData
{
    return _activeOperations > 0;
}

#pragma mark - Saving

- (void)save
{
    if (_isSaving) return;
    _isSaving = YES;
    
    [_mainContext performBlock:^{
        if ([_mainContext hasChanges]) {
            [_mainContext save:nil];
        }
        [_masterContext performBlock:^{
            if ([_masterContext hasChanges]) {
                NSError *error = nil;
                if (![_masterContext save:&error]) {
                    NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
                } else {
                    _lastSave = [NSDate date];
                }
            }
            _isSaving = NO;
        }];
    }];
}

#pragma mark - Reset

- (BOOL)reset
{
    if ([self isImportingData]) return NO;
    
    BOOL success = YES;
    
    NSURL *storeURL = [self persistentStoreURL];
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    NSManagedObjectContext *masterContext = [self masterContext];
    NSPersistentStore *store = [coordinator.persistentStores lastObject];
    
    // lock and reset context
    [masterContext lock];
    [masterContext reset];
    
    // remove store
    if (store) {
        NSError *removeStoreError = nil;
        if (![coordinator removePersistentStore:store error:&removeStoreError]) {
            NSLog(@"%@", removeStoreError);
            success = NO;
        }
    }
    
    // remove DB file
    if ([[NSFileManager defaultManager] fileExistsAtPath:storeURL.path]) {
        NSError *removeDBError = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:storeURL error:&removeDBError]) {
            NSLog(@"%@", removeDBError);
            success = NO;
        }
    }
    
    // unlock
    [masterContext unlock];
    
    // reset everything
    _backgroundContext = nil;
    _mainContext = nil;
    _masterContext = nil;
    _persistentStoreCoordinator = nil;
    _managedObjectModel = nil;
    
    // bring everything back
    [self mainContext];
    
    return success;
}

#pragma mark - Notifications

- (void)_listen
{
    __weak typeof(self) _self = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification){
                                                      [_self save];
                                                  }];
}

#pragma mark - Initialization

- (void)_start
{
    if (!_databaseName || !_modelName) {
        [NSException raise:@"Database name and model not set. setDatabaseName:linkedToModel: must be called before accessing shared manager."
                    format:nil];
        return;
    }
    
    // load everything
    [self mainContext];
    
    // check if store could not load
    if (!_persistentStore || !_persistentStoreCoordinator.persistentStores || !_persistentStoreCoordinator.persistentStores.count) {
        [self reset];
    }
    
    // consider this a save
    _lastSave = [NSDate date];
}

- (id)init
{
    [super doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithDatabaseName:(NSString *)databaseName linkedToModel:(NSString *)modelName
{
    self = [super init];
    if (self) {
        _databaseName = databaseName;
        _modelName = modelName;
        _saveInterval = TLSaveInterval;
        _activeOperations = 0;
        [self _start];
        [self _listen];
    }
    return self;
}

#pragma mark - Static Instance

+ (instancetype)sharedManager
{
    static TLDataManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initWithDatabaseName:TLDatabaseName linkedToModel:TLDatabaseModelName];
    });
    return instance;
}

@end
