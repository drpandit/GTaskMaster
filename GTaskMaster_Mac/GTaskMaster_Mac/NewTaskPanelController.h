//
//  NewTaskPanelController.h
//  GTaskMaster_Mac
//
//  Created by Kurt Hardin on 7/30/12.
//  Copyright (c) 2012 Kurt Hardin. All rights reserved.
//

#import "ModalSheetPanelController.h"
#import "GTaskMasterManagedObjects.h"

@interface NewTaskPanelController : ModalSheetController

@property (nonatomic, strong) GTaskMasterManagedTaskList *taskList;
@property (nonatomic, readonly, strong) IBOutlet NSTextField *titleTextField;
@property (nonatomic, readonly, strong) IBOutlet NSTextField *notesTextField;

@end
