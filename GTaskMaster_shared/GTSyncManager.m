//
//  GTSyncManger.m
//  GTaskMaster_Mac
//
//  Created by Kurt Hardin on 6/21/12.
//  Copyright (c) 2012 Kurt Hardin. All rights reserved.
//

#import "GTSyncManager.h"
#import "NSThread-MCSMAdditions/NSThread+MCSMAdditions.h"
#import "GTaskMasterManagedObjects.h"

@interface GTSyncManager ()

- (BOOL)startRepeatedSyncing;
- (BOOL)cancelRepeatedSyncing;
- (BOOL)sync;

- (void)addActiveServiceTicket:(GTLServiceTicket *)serviceTicket;
- (void)removeActiveServiceTicket:(GTLServiceTicket *)serviceTicket;

- (void)processServerTaskLists;
- (void)addTaskListToServer:(GTaskMasterManagedTaskList *)localTaskList;
- (void)updateTaskListOnServer:(GTaskMasterManagedTaskList *)localTaskList;
- (void)removeTaskListFromServer:(GTaskMasterManagedTaskList *)localTaskList;

- (void)processServerTasksForTaskList:(GTLTasksTaskList *)serverTaskList;
- (void)addTaskToServer:(GTaskMasterManagedTask *)localTask;
- (void)updateTaskOnServer:(GTaskMasterManagedTask *)localTask;

@end


int const kDefaultSyncIntervalSec = 300;


@implementation GTSyncManager

@synthesize isSyncing=_isSyncing;
@synthesize isRepeating=_isRepeating;
@synthesize delayInSeconds=_delayInSeconds;
@synthesize syncThread=_syncThread;
@synthesize syncRunloop=_syncRunloop;
@synthesize syncTimer=_syncTimer;
@synthesize taskManager=_taskManager;
@synthesize tasksService=_tasksService;
@synthesize activeServiceTickets=_activeServiceTickets;

+ (GTSyncManager *)sharedInstance {
    __strong static id _sharedObject = nil;
    
    static dispatch_once_t pred = 0;
    dispatch_once(&pred, ^{
        _sharedObject = [[self alloc] init];
    });
    
    return _sharedObject;
}

+ (void)setSyncDelay:(double)seconds {
    GTSyncManager *syncer = [GTSyncManager sharedInstance];
    [syncer setDelayInSeconds:seconds];
    if (syncer.isRepeating) {
        [syncer cancelRepeatedSyncing];
        [syncer startRepeatedSyncing];
    }
}

+ (BOOL)startSyncing {
    return [[GTSyncManager sharedInstance] startRepeatedSyncing];
}

+ (BOOL)startSyncingWithInterval:(double)seconds {
    GTSyncManager *syncer = [GTSyncManager sharedInstance];
    if (!syncer.isRepeating) {
        syncer.delayInSeconds = seconds;
        [syncer startRepeatedSyncing];
        return YES;
    }
    return NO;
}

+ (BOOL)stopSyncing {
    return [[GTSyncManager sharedInstance] cancelRepeatedSyncing];
}

+ (BOOL)syncNow {
    return [[GTSyncManager sharedInstance] sync];
}

- (id)init {
    self = [super init];
    if (self) {
        _isSyncing = NO;
        _isRepeating = NO;
        _delayInSeconds = kDefaultSyncIntervalSec;
        _syncThread = [[NSThread alloc] initWithTarget:self selector:@selector(syncThreadMain) object:nil];
        [_syncThread start];
        
        _activeServiceTickets = [NSMutableSet setWithCapacity:25];
    }
    return self;
}

- (LocalTaskManager *)taskManager {
    if (_taskManager == nil) {
        void (^taskManagerInitBlock)() = ^{
            _taskManager = [[LocalTaskManager alloc] init];
        };
        [self.syncThread MCSM_performBlock:taskManagerInitBlock waitUntilDone:YES];
    }
    return _taskManager;
}

- (GTLServiceTasks *)tasksService {
    if (!_tasksService) {
        _tasksService = [[GTLServiceTasks alloc] init];
        _tasksService.shouldFetchNextPages = YES;
        _tasksService.retryEnabled = YES;
    }
    return _tasksService;
}

- (BOOL)startRepeatedSyncing {
    if (!self.isRepeating) {
        _isRepeating = YES;
        [self sync];
        _syncTimer = [NSTimer timerWithTimeInterval:self.delayInSeconds
                                             target:self
                                           selector:@selector(sync)
                                           userInfo:nil
                                            repeats:YES];
        [self.syncRunloop addTimer:self.syncTimer
                           forMode:NSDefaultRunLoopMode];
        return YES;
    }
    return NO;
}

- (BOOL)cancelRepeatedSyncing {
    if (self.isRepeating) {
        if (self.syncTimer) {
            [self.syncTimer invalidate];
            _syncTimer = nil;
        }
        _isRepeating = NO;
        return YES;
    }
    return NO;
}

- (BOOL)sync {
    BOOL syncStarted = NO;
    
    if (!self.isSyncing) {
        _isSyncing = YES;
        [self performSelector:@selector(processServerTaskLists) onThread:self.syncThread withObject:nil waitUntilDone:NO];
        syncStarted = YES;
    }
    
    return syncStarted;
}

- (void)addActiveServiceTicket:(GTLServiceTicket *)serviceTicket {
    [_activeServiceTickets addObject:serviceTicket];
    _isSyncing = YES;
}

- (void)removeActiveServiceTicket:(GTLServiceTicket *)serviceTicket {
    [_activeServiceTickets removeObject:serviceTicket];
    if (_activeServiceTickets.count == 0) {
        _isSyncing = NO;
    }
}

#pragma mark - TaskList methods

- (void)processServerTaskLists {
    
    // Setup code block to run on completion of query executed below
    void (^completionHandler)();
    completionHandler = ^(GTLServiceTicket *ticket,
                          id serverTaskLists, NSError *error) {
        
        if (error) {
            NSLog(@"Error fetching task lists from server:\n  %@", error);
        } else {
            NSMutableArray *localTaskLists = [NSMutableArray arrayWithArray:[self.taskManager taskLists]];
            
            if (serverTaskLists) {
                for (GTLTasksTaskList *serverTaskList in serverTaskLists) {
                    
                    NSDate *serverModDate = serverTaskList.updated.date;
                    GTaskMasterManagedTaskList *localTaskList = [self.taskManager taskListWithId:serverTaskList.identifier];
                    
                    BOOL shouldProcessTasksForTaskList = YES;
                    if (localTaskList == nil) {
                        [self.taskManager addTaskList:serverTaskList];
                        
                    } else if (localTaskList.deleted) {
                        [self removeTaskListFromServer:serverTaskList];
                        shouldProcessTasksForTaskList = NO;
                        
                    } else {
                        NSDate *localSyncDate = localTaskList.synced;
                        NSDate *localModDate = localTaskList.updated;
                        if (![localSyncDate isEqualToDate:localModDate]) {
                            if ([localSyncDate isEqualToDate:serverModDate]) {
                                [self updateTaskListOnServer:localTaskList];
                            } else {
#pragma mark TODO: Resolve conflict
                            }
                            
                        } else if (![localSyncDate isEqualToDate:serverModDate]) {
                            [self.taskManager updateTaskList:serverTaskList];
                            
                        } else {
                           shouldProcessTasksForTaskList = NO; 
                            
                        }
                        
                    }
                    
                    if (shouldProcessTasksForTaskList) {
                        [self processServerTasksForTaskList:serverTaskList];
                    }
                    
                    [localTaskLists removeObject:localTaskList];
                }
            }
            
            if (localTaskLists.count > 0) {
                for (GTaskMasterManagedTaskList *localTaskList in localTaskLists) {
                    if ([localTaskList isNew]) {
                        [self addTaskListToServer:localTaskList];
                    } else {
                        [self.taskManager removeTaskListWithId:localTaskList.identifier];
                    }
                }
            }
            
            [self removeActiveServiceTicket:ticket];
        }
    };
    
    [self addActiveServiceTicket:[self.tasksService executeQuery:[GTLQueryTasks queryForTasklistsList]
                                               completionHandler:completionHandler]];
}

- (BOOL)addTaskList:(GTaskMasterManagedTaskList *)taskList {
    if (!self.isSyncing) {
        [self addTaskListToServer:taskList];
        return YES;
    }
    return NO;
}

- (void)addTaskListToServer:(GTaskMasterManagedTaskList *)localTaskList {
    if ([localTaskList.title length] > 0) {
        GTLTasksTaskList *tasklist = [localTaskList createGTLTasksTaskList];
        
        GTLQueryTasks *query = [GTLQueryTasks queryForTasklistsInsertWithObject:tasklist];
        
        [self addActiveServiceTicket:[self.tasksService executeQuery:query
                                                   completionHandler:^(GTLServiceTicket *ticket,
                                                                       id newTaskList, NSError *error) {
                                                       if (error) {
                                                           NSLog(@"Error adding task to server:\n  %@", error);
                                                       } else {
                                                           [self.taskManager updateTaskList:newTaskList];
                                                           [self processServerTasksForTaskList:newTaskList];
                                                       }
                                                       
                                                       [self removeActiveServiceTicket:ticket];
                                                       
                                                   }]];
    }
}

- (BOOL)updateTaskList:(GTaskMasterManagedTaskList *)taskList {
    if (!self.isSyncing) {
        [self updateTaskListOnServer:taskList];
        return YES;
    }
    return NO;
}

- (void)updateTaskListOnServer:(GTaskMasterManagedTaskList *)localTaskList {
    if ([localTaskList.title length] > 0) {
        GTLTasksTaskList *patchObject = [localTaskList createGTLTasksTaskList];
        
        GTLQueryTasks *query = [GTLQueryTasks queryForTasklistsPatchWithObject:patchObject
                                                                      tasklist:localTaskList.identifier];
        
        [self addActiveServiceTicket:[self.tasksService executeQuery:query
                                                   completionHandler:^(GTLServiceTicket *ticket,
                                                                       id updatedTaskList, NSError *error) {
                                                       if (error) {
                                                           NSLog(@"Error updating task list:\n  %@", error);
                                                       } else {
                                                           [self.taskManager updateTaskList:updatedTaskList];
                                                       }
                                                       
                                                       [self removeActiveServiceTicket:ticket];
                                                   }]];
    }
}

- (BOOL)removeTaskList:(GTaskMasterManagedTaskList *)taskList {
    if (!self.isSyncing) {
        [self removeTaskListFromServer:taskList];
        return YES;
    }
    return NO;
}

- (void)removeTaskListFromServer:(GTaskMasterManagedTaskList *)localTaskList {
    
    GTLQueryTasks *query = [GTLQueryTasks queryForTasklistsDeleteWithTasklist:localTaskList.identifier];
    
    [self addActiveServiceTicket:[self.tasksService executeQuery:query
                                               completionHandler:^(GTLServiceTicket *ticket,
                                                                   id item, NSError *error) {
                                                   
                                                   if (error == nil) {
//                                                       [self.taskManager removeTaskListWithId:localTaskList.identifier];
                                                   } else {
                                                       NSLog(@"Error removing task list:\n  %@", error);
                                                   }
                                                   
                                                   [self removeActiveServiceTicket:ticket];
                                               }]];
}

#pragma mark - Task methods

- (void)processServerTasksForTaskList:(GTLTasksTaskList *)serverTaskList {
    
    GTLQueryTasks *query = [GTLQueryTasks queryForTasksListWithTasklist:serverTaskList.identifier];
    query.showCompleted = YES;
    query.showHidden = YES;
    query.showDeleted = YES;
    query.maxResults = 1000;
    
    [self addActiveServiceTicket:[self.tasksService executeQuery:query
                                               completionHandler:^(GTLServiceTicket *ticket,
                                                                   id serverTasks, NSError *error) {
                                                   if (error) {
#pragma mark TODO: Present error
                                                   } else {
                                                       NSMutableOrderedSet *localTasks = [NSMutableOrderedSet orderedSetWithOrderedSet:[self.taskManager taskListWithId:serverTaskList.identifier].tasks];
                                                       
                                                       int processedCount = 0;
                                                       int addedCount = 0;
                                                       for (GTLTasksTask *serverTask in serverTasks) {
                                                           
                                                           GTaskMasterManagedTask *localTask = [self.taskManager taskWithId:serverTask.identifier];
                                                           if (localTask == nil) {
                                                               [self.taskManager addTask:serverTask toList:serverTaskList.identifier];
                                                               addedCount++;
                                                               
                                                           } else {
                                                               NSDate *serverModDate = serverTask.updated.date;
                                                               NSDate *localModDate = localTask.updated;
                                                               NSDate *localSyncDate = localTask.synced;
                                                               if (![localModDate isEqualToDate:localSyncDate]) {
                                                                   if ([localSyncDate isEqualToDate:serverModDate]) {
                                                                       [self updateTaskOnServer:localTask];
                                                                   } else {
# pragma mark TODO: Resolve sync conflict
                                                                   }
                                                               } else if (![localSyncDate isEqualToDate:serverModDate]) {
                                                                   [self.taskManager updateTask:serverTask];
                                                               }
                                                               
                                                               [localTasks removeObject:localTask];
                                                           }
                                                           
                                                           processedCount++;
                                                       }
                                                       
                                                       NSLog(@"Processed %d tasks from server, %d added\n\n", processedCount, addedCount);
                                                       
                                                       if (localTasks.count > 0) {
                                                           for (GTaskMasterManagedTask *task in localTasks) {
                                                               [self addTaskToServer:task];
                                                           }
                                                       }
                                                   }
                                                   
                                                   [self removeActiveServiceTicket:ticket];
                                               }]];
}

- (void)executeTaskQuery:(GTLQueryTasks *)taskQuery withErrorMessage:(NSString *)errMsg {
    [self addActiveServiceTicket:[self.tasksService executeQuery:taskQuery
                                               completionHandler:^(GTLServiceTicket *ticket,
                                                                   id serverTask, NSError *error) {
                                                   if (error) {
                                                       NSLog(@"%@:\n  %@", errMsg, error);
                                                   } else {
                                                       [self.taskManager updateTask:serverTask];
                                                   }
                                                   
                                                   [self removeActiveServiceTicket:ticket];
                                               }]];
}

- (BOOL)addTask:(GTaskMasterManagedTask *)task {
    if (!self.isSyncing) {
        [self addTaskToServer:task];
        return YES;
    }
    return NO;
}

- (void)addTaskToServer:(GTaskMasterManagedTask *)localTask {
    GTLTasksTask *taskToAdd = [localTask createGTLTasksTask];
    if (taskToAdd.title.length > 0) {
        GTLQueryTasks *query = [GTLQueryTasks queryForTasksInsertWithObject:taskToAdd
                                                                   tasklist:localTask.tasklist.identifier];
        [self executeTaskQuery:query withErrorMessage:@"Error adding task to server"];
    }
}

- (BOOL)updateTask:(GTaskMasterManagedTask *)task {
    if (!self.isSyncing) {
        [self updateTaskOnServer:task];
        return YES;
    }
    return NO;
}

- (void)updateTaskOnServer:(GTaskMasterManagedTask *)localTask {
    GTLTasksTask *taskToPatch = [localTask createGTLTasksTask];
    if (taskToPatch.title.length > 0) {
        GTLQueryTasks *query = [GTLQueryTasks queryForTasksPatchWithObject:taskToPatch 
                                                                  tasklist:localTask.tasklist.identifier 
                                                                      task:localTask.identifier];
        [self executeTaskQuery:query withErrorMessage:@"Error updating task on server"];
    }
}
     
#pragma mark - NSThread methods

- (void) syncThreadKeepAlive {
    [self performSelector:@selector(syncThreadKeepAlive) withObject:nil afterDelay:300];
}
     
- (void)syncThreadMain {
    // Add selector to prevent CFRunLoopRunInMode from returning immediately
    [self performSelector:@selector(imageSaverKeepAlive) withObject:nil afterDelay:300];
    BOOL done = NO;
    
    _syncRunloop = [NSRunLoop currentRunLoop];
    
    do {
        SInt32 result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, YES);
        if ((result == kCFRunLoopRunStopped) || (result == kCFRunLoopRunFinished))
            done = YES;
    }
    while (!done);
}

@end
