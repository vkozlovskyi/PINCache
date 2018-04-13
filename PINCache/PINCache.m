//  PINCache is a modified version of PINCache
//  Modifications by Garrett Moon
//  Copyright (c) 2015 Pinterest. All rights reserved.

#import "PINCache.h"

NSString * const PINCachePrefix = @"com.pinterest.PINCache";
NSString * const PINCacheSharedName = @"PINCacheShared";

@interface PINCache ()
#if OS_OBJECT_USE_OBJC
@property (strong, nonatomic) dispatch_queue_t concurrentQueue;
#else
@property (assign, nonatomic) dispatch_queue_t concurrentQueue;
#endif
@end

@implementation PINCache

#pragma mark - Initialization -

#if !OS_OBJECT_USE_OBJC
- (void)dealloc
{
    dispatch_release(_concurrentQueue);
    _concurrentQueue = nil;
}
#endif

- (instancetype)init
{
  @throw [NSException exceptionWithName:@"Must initialize with a name" reason:@"PINCache must be initialized with a name. Call initWithName: instead." userInfo:nil];
  return [self initWithName:@""];
}

- (instancetype)initWithName:(NSString *)name
{
    return [self initWithName:name rootPath:[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject]];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath
{
    if (!name)
        return nil;
    
    if (self = [super init]) {
        _name = [name copy];
        
      NSString *queueName = [[NSString alloc] initWithFormat:@"%@.%@", PINCachePrefix, self];
        _concurrentQueue = dispatch_queue_create([[NSString stringWithFormat:@"%@ Asynchronous Queue", queueName] UTF8String], DISPATCH_QUEUE_CONCURRENT);
        
        _diskCache = [[PINDiskCache alloc] initWithName:_name rootPath:rootPath];
        _memoryCache = [[PINMemoryCache alloc] init];
    }
    return self;
}

- (NSString *)description
{
    return [[NSString alloc] initWithFormat:@"%@.%@.%p", PINCachePrefix, _name, (void *)self];
}

+ (instancetype)sharedCache
{
    static id cache;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        cache = [[self alloc] initWithName:PINCacheSharedName];
    });
    
    return cache;
}

#pragma mark - Public Asynchronous Methods -


- (void)objectForKey:(NSString *)key block:(PINCacheObjectBlock)block
{
    [self objectForKey:key readBlock:nil block:block];
}

- (void)objectForKey:(NSString *)key readBlock:(PINCacheReadBlock)readBlock block:(PINCacheObjectBlock)block
{
    if (!key || !block)
        return;

    __weak PINCache *weakSelf = self;

    dispatch_async(_concurrentQueue, ^{
        PINCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        __weak PINCache *weakSelf = strongSelf;

        [strongSelf->_memoryCache objectForKey:key block:^(PINMemoryCache *cache, NSString *key, id object) {
            PINCache *strongSelf = weakSelf;
            if (!strongSelf)
                return;

            if (object) {
                [strongSelf->_diskCache fileURLForKey:key block:^(PINDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
                    // update the access time on disk
                }];

                __weak PINCache *weakSelf = strongSelf;

                dispatch_async(strongSelf->_concurrentQueue, ^{
                    PINCache *strongSelf = weakSelf;
                    if (strongSelf)
                        block(strongSelf, key, object);
                });
            } else {
                __weak PINCache *weakSelf = strongSelf;

                PINDiskCacheReadBlock diskReadBlock = nil;
                if (readBlock) {
                    diskReadBlock = ^id (PINDiskCache *cache, NSString *key, NSURL *fileURL){
                        return readBlock(self, key, fileURL);
                    };
                }

                [strongSelf->_diskCache objectForKey:key readBlock:diskReadBlock block:^(PINDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
                    PINCache *strongSelf = weakSelf;
                    if (!strongSelf)
                        return;

                    [strongSelf->_memoryCache setObject:object forKey:key block:nil];

                    __weak PINCache *weakSelf = strongSelf;

                    dispatch_async(strongSelf->_concurrentQueue, ^{
                        PINCache *strongSelf = weakSelf;
                        if (strongSelf)
                            block(strongSelf, key, object);
                    });
                }];
            }
        }];
    });
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key block:(PINCacheObjectBlock)block
{
    [self setObject:object forKey:key writeBlock:nil block:block];
}

- (void)setObject:(id)object forKey:(NSString *)key writeBlock:(PINCacheWriteBlock)writeBlock block:(PINCacheObjectBlock)block
{
    if (!key || !object)
        return;

    dispatch_group_t group = nil;
    PINMemoryCacheObjectBlock memBlock = nil;
    PINDiskCacheObjectBlock diskBlock = nil;

    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);

        memBlock = ^(PINMemoryCache *cache, NSString *key, id object) {
            dispatch_group_leave(group);
        };

        diskBlock = ^(PINDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
            dispatch_group_leave(group);
        };
    }

    [_memoryCache setObject:object forKey:key block:memBlock];

    PINDiskCacheWriteBlock diskWriteBlock = nil;
    if (writeBlock) {
        diskWriteBlock = ^BOOL (PINDiskCache *cache, NSString *key, NSURL *fileURL, id object){
            return writeBlock(self, key, fileURL, object);
        };
    }

    [_diskCache setObject:object forKey:key writeBlock:diskWriteBlock block:diskBlock];

    if (group) {
        __weak PINCache *weakSelf = self;
        dispatch_group_notify(group, _concurrentQueue, ^{
            PINCache *strongSelf = weakSelf;
            if (strongSelf)
                block(strongSelf, key, object);
        });

#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

- (void)removeObjectForKey:(NSString *)key block:(PINCacheObjectBlock)block
{
    if (!key)
        return;
    
    dispatch_group_t group = nil;
    PINMemoryCacheObjectBlock memBlock = nil;
    PINDiskCacheObjectBlock diskBlock = nil;
    
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        
        memBlock = ^(PINMemoryCache *cache, NSString *key, id object) {
            dispatch_group_leave(group);
        };
        
        diskBlock = ^(PINDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
            dispatch_group_leave(group);
        };
    }
    
    [_memoryCache removeObjectForKey:key block:memBlock];
    [_diskCache removeObjectForKey:key block:diskBlock];
    
    if (group) {
        __weak PINCache *weakSelf = self;
        dispatch_group_notify(group, _concurrentQueue, ^{
            PINCache *strongSelf = weakSelf;
            if (strongSelf)
                block(strongSelf, key, nil);
        });
        
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

- (void)removeAllObjects:(PINCacheBlock)block
{
    dispatch_group_t group = nil;
    PINMemoryCacheBlock memBlock = nil;
    PINDiskCacheBlock diskBlock = nil;
    
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        
        memBlock = ^(PINMemoryCache *cache) {
            dispatch_group_leave(group);
        };
        
        diskBlock = ^(PINDiskCache *cache) {
            dispatch_group_leave(group);
        };
    }
    
    [_memoryCache removeAllObjects:memBlock];
    [_diskCache removeAllObjects:diskBlock];
    
    if (group) {
        __weak PINCache *weakSelf = self;
        dispatch_group_notify(group, _concurrentQueue, ^{
            PINCache *strongSelf = weakSelf;
            if (strongSelf)
                block(strongSelf);
        });
        
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

- (void)trimToDate:(NSDate *)date block:(PINCacheBlock)block
{
    [self trimObjectsForKeys:nil toDate:date block:block];
}

- (void)trimObjectsForKeys:(NSArray *)keys toDate:(NSDate *)date block:(nullable PINCacheBlock)block
{
    if (!date)
        return;
    
    dispatch_group_t group = nil;
    PINMemoryCacheBlock memBlock = nil;
    PINDiskCacheBlock diskBlock = nil;
    
    if (block) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_group_enter(group);
        
        memBlock = ^(PINMemoryCache *cache) {
            dispatch_group_leave(group);
        };
        
        diskBlock = ^(PINDiskCache *cache) {
            dispatch_group_leave(group);
        };
    }
    
    [_memoryCache trimToDate:date block:memBlock];
    [_diskCache trimObjectsForKeys:keys toDate:date block:diskBlock];
    
    if (group) {
        __weak PINCache *weakSelf = self;
        dispatch_group_notify(group, _concurrentQueue, ^{
            PINCache *strongSelf = weakSelf;
            if (strongSelf)
                block(strongSelf);
        });
        
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    }
}

#pragma mark - Public Synchronous Accessors -

- (NSUInteger)diskByteCount
{
    __block NSUInteger byteCount = 0;
    
    [_diskCache synchronouslyLockFileAccessWhileExecutingBlock:^(PINDiskCache *diskCache) {
        byteCount = diskCache.byteCount;
    }];
    
    return byteCount;
}

- (id)objectForKey:(NSString *)key
{
    return [self objectForKey:key readBlock:nil];
}

- (id)objectForKey:(NSString *)key readBlock:(PINCacheReadBlock)readBlock
{
    if (!key)
        return nil;

    __block id object = nil;

    object = [_memoryCache objectForKey:key];

    if (object) {
        // update the access time on disk
        [_diskCache fileURLForKey:key block:NULL];
    } else {
        PINDiskCacheReadBlock diskReadBlock = nil;
        if (readBlock) {
            diskReadBlock = ^id (PINDiskCache *cache, NSString *diskKey, NSURL *fileURL) {
                return readBlock(self, key, fileURL);
            };
        }

        object = [_diskCache objectForKey:key readBlock:diskReadBlock];
        [_memoryCache setObject:object forKey:key];
    }

    return object;
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key
{
    [self setObject:object forKey:key writeBlock:nil];
}

- (void)setObject:(id)object forKey:(NSString *)key writeBlock:(PINCacheWriteBlock)writeBlock
{
    if (!key || !object)
        return;

    [_memoryCache setObject:object forKey:key];

    PINDiskCacheWriteBlock diskWriteBlock = nil;
    if (writeBlock) {
        diskWriteBlock = ^BOOL (PINDiskCache *cache, NSString *diskKey, NSURL *fileURL, id diskObject) {
            return writeBlock(self, key, fileURL, object);
        };
    }
    [_diskCache setObject:object forKey:key writeBlock:diskWriteBlock];
}

- (void)setObjectAtURL:(NSURL *)URL forKey:(NSString *)key copy:(BOOL)copy
{
    if (!key || !URL)
        return;
    
    PINDiskCacheWriteBlock writeBlock = ^BOOL (PINDiskCache *cache, NSString *diskKey, NSURL *fileURL, id diskObject) {
        NSFileManager *manager = [NSFileManager defaultManager];
        [manager removeItemAtURL:fileURL error:nil];
        
        BOOL result = NO;
        if (copy) {
            result = [manager copyItemAtURL:URL toURL:fileURL error:nil];
        } else {
            result = [manager moveItemAtURL:URL toURL:fileURL error:nil];
        }
        
        return result;
    };
    [_diskCache setObject:URL forKey:key writeBlock:writeBlock];
}

- (void)removeObjectForKey:(NSString *)key
{
    if (!key)
        return;
    
    [_memoryCache removeObjectForKey:key];
    [_diskCache removeObjectForKey:key];
}

- (void)trimObjectsForKeys:(NSArray * __nullable)keys toDate:(NSDate *)date
{
    if (!date)
        return;
    
    [_memoryCache trimToDate:date];
    [_diskCache trimObjectsForKeys:keys toDate:date];
}

- (void)trimToDate:(NSDate *)date
{
    [self trimObjectsForKeys:nil toDate:date];
}

- (void)removeAllObjects
{
    [_memoryCache removeAllObjects];
    [_diskCache removeAllObjects];
}

@end
