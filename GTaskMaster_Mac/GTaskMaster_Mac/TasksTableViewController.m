//
//  TasksTableViewController.m
//  GTaskMaster_Mac
//
//  Created by Kurt Hardin on 7/16/12.
//  Copyright (c) 2012 Kurt Hardin. All rights reserved.
//

#import "TasksTableViewController.h"
#import "AppDelegate.h"
#import "GTSyncManager.h"

@implementation TasksTableViewController

@synthesize taskListsController;
@synthesize tasklistsTableView;
@synthesize tasksController;
@synthesize tasksTableView;

AppDelegate *_appDelegate;

- (void)awakeFromNib {
    _appDelegate = (AppDelegate *) [NSApplication sharedApplication].delegate;
    
    [self.taskListsController setSortDescriptors:[NSArray arrayWithObject:[NSSortDescriptor sortDescriptorWithKey:@"title" ascending:NSOrderedAscending]]];
    
    NSArray *taskSortDescriptors = [NSArray arrayWithObjects:
                                    [NSSortDescriptor sortDescriptorWithKey:@"completed" ascending:NSOrderedDescending],
                                    [NSSortDescriptor sortDescriptorWithKey:@"position" ascending:NSOrderedAscending],
                                    nil];
    [self.tasksController setSortDescriptors:taskSortDescriptors];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshTableViews)
                                                 name:NSManagedObjectContextDidSaveNotification
                                               object:[GTSyncManager sharedInstance].taskManager.managedObjectContext];
}

- (void)selectTask:(GTaskMasterManagedTask *)task {
    NSIndexSet *taskListIndexes = [self.taskListsController.arrangedObjects indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
        GTaskMasterManagedTaskList *taskList = obj;
        if ([taskList.identifier isEqualToString:task.tasklist.identifier]) {
            *stop = YES;
            return YES;
        }
        return NO;
    }];
    [self.taskListsController setSelectionIndexes:taskListIndexes];
    
    NSIndexSet *taskIndexes = [self.tasksController.arrangedObjects indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
        GTaskMasterManagedTask *currentTask = obj;
        if ([currentTask.identifier isEqualToString:task.identifier]) {
            *stop = YES;
            return YES;
        }
        return NO;
    }];
    [self.tasksController setSelectionIndexes:taskIndexes];
}

- (void)refreshTableViews {
    [self.tasklistsTableView reloadData];
    [self.tasksTableView reloadData];
}

- (GTaskMasterManagedTaskList *)selectedTaskList {
    if (self.taskListsController.selectedObjects.count > 0) {
        return [self.taskListsController.selectedObjects objectAtIndex:0];
    }
    return nil;
}

- (GTaskMasterManagedTask *)selectedTask {
    if (self.tasksController.selectedObjects.count > 0) {
        return [self.tasksController.selectedObjects objectAtIndex:0];
    }
    return nil;
}

- (IBAction)showTaskListInfo:(id)sender {
    GTaskMasterManagedTaskList *tasklist = [self selectedTaskList];
    if (tasklist) {
        NSLog(@"%@", tasklist);
    }
}

- (IBAction)addTaskList:(id)sender {
    [_appDelegate.taskListCreationPanelController show];
}

- (IBAction)showTaskInfo:(id)sender {
    GTaskMasterManagedTask *task = [self selectedTask];
    if (task) {
        NSLog(@"%@", task);
    }
}

- (IBAction)addTask:(id)sender {
    GTaskMasterManagedTaskList *selectedTasklist = [self selectedTaskList];
    if (selectedTasklist) {
        [_appDelegate.taskCreationPanelController setTaskList:selectedTasklist];
        [_appDelegate.taskCreationPanelController show];
        
    } else {
        NSLog(@"Failed to add task, no task list selected...");
        
    }
}

#pragma mark - NSTableViewDelegate methods

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if ([notification.object isEqualTo:self.tasklistsTableView]) {
        GTaskMasterManagedTaskList *selectedTasklist = [self selectedTaskList];
        if (selectedTasklist) {
            [self.tasksController setFetchPredicate:[NSPredicate predicateWithFormat:@"tasklist.identifier == %@", selectedTasklist.identifier]];
            [self.tasksController fetch:self];
            [self.tasksTableView reloadData];
        }
    }
}

@end
