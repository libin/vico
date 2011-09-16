#import <Quartz/Quartz.h>

#import "ViFileExplorer.h"
#import "logging.h"
#import "MHTextIconCell.h"
#import "ViWindowController.h"
#import "ViError.h"
#import "NSString-additions.h"
#import "ViDocumentController.h"
#import "ViURLManager.h"
#import "ViCompletion.h"
#import "ViCompletionController.h"
#import "NSObject+SPInvocationGrabbing.h"
#import "ViCommon.h"
#import "NSURL-additions.h"
#import "ViBgView.h"
#import "ViWindow.h"
#import "ViEventManager.h"
#import "ViPathComponentCell.h"
#import "ViCommandMenuItemView.h"
#import "NSMenu-additions.h"

@interface ViFileExplorer (private)
- (void)recursivelySortProjectFiles:(NSMutableArray *)children;
- (NSString *)relativePathForItem:(NSDictionary *)item;
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item;
- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)anIndex ofItem:(id)item;
- (void)expandNextItem;
- (void)expandItems:(NSArray *)items recursionLimit:(int)recursionLimit;
- (void)sortProjectFiles:(NSMutableArray *)children;
- (BOOL)rescan_files:(ViCommand *)command;
- (NSMutableArray *)filteredContents:(NSArray *)contents ofDirectory:(NSURL *)url;
- (void)resetExpandedItems;
- (id)findItemWithURL:(NSURL *)aURL inItems:(NSArray *)items;
- (id)findItemWithURL:(NSURL *)aURL;
- (NSInteger)rowForItemWithURL:(NSURL *)aURL;
- (BOOL)selectItemAtRow:(NSInteger)row;
- (BOOL)selectItem:(id)item;
- (BOOL)selectItemWithURL:(NSURL *)aURL;
- (void)rescanURL:(NSURL *)aURL
     onlyIfCached:(BOOL)cacheFlag
     andRenameURL:(NSURL *)renameURL;
- (void)rescanURL:(NSURL *)aURL;
- (void)resetExplorerView;
- (void)showAltFilterField;
- (void)hideAltFilterField;
- (void)closeExplorerAndFocusEditor:(BOOL)focusEditor;
- (NSIndexSet *)clickedIndexes;
@end


@implementation ViFileExplorer

@synthesize delegate;
@synthesize outlineView = explorer;
@synthesize rootURL;

- (id)init
{
	self = [super init];
	if (self) {
		history = [[ViJumpList alloc] init];
		[history setDelegate:self];
		font = [NSFont systemFontOfSize:11.0];
		expandedSet = [NSMutableSet set];
		contextObjects = [NSMutableSet set];
		width = 200.0;
		statusImages = [NSMutableDictionary dictionary];
	}
	return self;
}

- (void)compileSkipPattern
{
	NSError *error = nil;
	skipRegex = [[ViRegexp alloc] initWithString:[[NSUserDefaults standardUserDefaults] stringForKey:@"skipPattern"] options:0 error:&error];
	if (error) {
		[windowController message:@"Invalid regular expression in skipPattern: %@", [error localizedDescription]];
		skipRegex = nil;
	}
}

- (void)awakeFromNib
{
	explorer.strictIndentation = YES;
	explorer.keyManager = [[ViKeyManager alloc] initWithTarget:self
							defaultMap:[ViMap explorerMap]];
	[explorer setTarget:self];
	[explorer setDoubleAction:@selector(explorerDoubleClick:)];
	[explorer setAction:@selector(explorerClick:)];
	[[sftpConnectForm cellAtIndex:1] setPlaceholderString:NSUserName()];
	[actionButtonCell setImage:[NSImage imageNamed:@"actionmenu"]];
	[actionButton setMenu:actionMenu];
	[actionMenu setDelegate:self];
	[actionMenu setFont:[NSFont menuFontOfSize:0]];

	explorerView.backgroundColor = [explorer backgroundColor];

	[[NSUserDefaults standardUserDefaults] addObserver:self
						forKeyPath:@"explorecaseignore"
						   options:NSKeyValueObservingOptionNew
						   context:NULL];
	[[NSUserDefaults standardUserDefaults] addObserver:self
						forKeyPath:@"exploresortfolders"
						   options:NSKeyValueObservingOptionNew
						   context:NULL];

	[self compileSkipPattern];
	[[NSUserDefaults standardUserDefaults] addObserver:self
						forKeyPath:@"skipPattern"
						   options:NSKeyValueObservingOptionNew
						   context:NULL];

	[[NSNotificationCenter defaultCenter] addObserver:self
						 selector:@selector(URLContentsWasCached:)
						     name:ViURLContentsCachedNotification
						   object:[ViURLManager defaultManager]];

	[[NSNotificationCenter defaultCenter] addObserver:self
						 selector:@selector(firstResponderChanged:)
						     name:ViFirstResponderChangedNotification
						   object:nil];

	[[NSNotificationCenter defaultCenter] addObserver:self
						 selector:@selector(documentEditedChanged:)
						     name:ViDocumentEditedChangedNotification
						   object:nil];

	[pathControl setTarget:self];
	[pathControl setAction:@selector(pathControlAction:)];

	NSRect frame = [pathControl frame];
	frame.size.height = 22;
	[pathControl setFrame:frame];
}

- (void)pathControlAction:(id)sender
{
	NSURL *url = nil;
	NSPathComponentCell *cell = [sender clickedPathComponentCell];
	if (cell)
		url = [cell URL];
	else
		url = [pathControl URL];
	if (url)
		[self browseURL:url];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
		      ofObject:(id)object
			change:(NSDictionary *)change
		       context:(void *)context
{
	if ([keyPath isEqualToString:@"skipPattern"]) {
		[self compileSkipPattern];
		rootItems = nil;
		[explorer reloadData];
		[self browseURL:rootURL];
		return;
	}

	/* only explorecaseignore, exploresortfolders and skipPattern options observed */
	/* re-sort explorer */
	if (rootItems) {
		[self recursivelySortProjectFiles:rootItems];
		if (!isFiltered)
			[self filterFiles:self];
	}
}

- (ViFile *)fileForItem:(id)item
{
	if ([item isKindOfClass:[ViCompletion class]])
		return [(ViCompletion *)item representedObject];
	return item;
}

- (NSMutableArray *)filteredContents:(NSArray *)files ofDirectory:(NSURL *)url
{
	DEBUG(@"filtering files in %@", url);
	if (files == nil)
		return nil;

	id olditem = [self findItemWithURL:url];

	NSMutableArray *children = [NSMutableArray array];
	for (ViFile *file in files) {
		if ([skipRegex matchInString:file.name] == nil) {
			if ([file isDirectory]) {
				ViFile *oldPf = nil;
				if (olditem)
					oldPf = [self findItemWithURL:file.url inItems:[[self fileForItem:olditem] children]];
				if (oldPf && [oldPf hasCachedChildren]) {
					DEBUG(@"re-using old children of file %@", oldPf);
					file.children = oldPf.children;
				} else {
					NSArray *contents = [[ViURLManager defaultManager] cachedContentsOfDirectoryAtURL:file.url];
					file.children = [self filteredContents:contents
								   ofDirectory:file.url];
				}
			}
			[children addObject:file];
		}
	}

	[self sortProjectFiles:children];

	return children;
}

- (void)childrenAtURL:(NSURL *)url onCompletion:(void (^)(NSMutableArray *, NSError *))aBlock
{
	ViURLManager *um = [ViURLManager defaultManager];

	id<ViDeferred> deferred = [um contentsOfDirectoryAtURL:url onCompletion:^(NSArray *files, NSError *error) {
		[progressIndicator setHidden:YES];
		[progressIndicator stopAnimation:nil];
		if (error) {
			INFO(@"failed to read contents of folder %@", url);
			aBlock(nil, error);
		} else {
			NSMutableArray *children = [self filteredContents:files ofDirectory:url];
			aBlock(children, nil);
		}
	}];

	if (deferred) {
		[progressIndicator setHidden:NO];
		[progressIndicator startAnimation:nil];
	}
}

- (void)sortProjectFiles:(NSMutableArray *)children
{
	BOOL sortFolders = [[NSUserDefaults standardUserDefaults] boolForKey:@"exploresortfolders"];
	BOOL caseIgnoreSort = [[NSUserDefaults standardUserDefaults] boolForKey:@"explorecaseignore"];

	NSStringCompareOptions sortOptions = 0;
	if (caseIgnoreSort)
		sortOptions = NSCaseInsensitiveSearch;

	[children sortUsingComparator:^(id obj1, id obj2) {
		if (sortFolders) {
			if ([obj1 isDirectory]) {
				if (![obj2 isDirectory])
					return (NSComparisonResult)NSOrderedAscending;
			} else if ([obj2 isDirectory])
				return (NSComparisonResult)NSOrderedDescending;
		}
		return [[obj1 displayName] compare:[obj2 displayName] options:sortOptions];
	}];
}

- (void)recursivelySortProjectFiles:(NSMutableArray *)children
{
	[self sortProjectFiles:children];

	for (ViFile *file in children)
		if ([file hasCachedChildren] && [file isDirectory])
			[self recursivelySortProjectFiles:[file children]];
}

- (BOOL)isEditing
{
	return [explorer editedRow] != -1;
}

- (void)browseURL:(NSURL *)aURL andDisplay:(BOOL)display jump:(BOOL)jump
{
	NSParameterAssert(aURL);

	[self childrenAtURL:aURL onCompletion:^(NSMutableArray *children, NSError *error) {
		if (error) {
			NSAlert *alert = [NSAlert alertWithError:error];
			[alert runModal];
		} else {
			if (jump)
				[history pushURL:rootURL line:0 column:0 view:nil];
			if (display)
				[self openExplorerTemporarily:NO];
			rootItems = children;
			[self filterFiles:self];
			[self resetExpandedItems];
			[pathControl setURL:aURL];
			rootURL = aURL;
			[windowController setBaseURL:aURL];

			if (!jump || ([[explorer selectedRowIndexes] count] == 0 && [window firstResponder] == explorer))
				[self selectItemAtRow:0];

			[[ViEventManager defaultManager] emit:ViEventExplorerRootChanged for:self with:self, rootURL, nil];
		}
	}];
}

- (void)browseURL:(NSURL *)aURL andDisplay:(BOOL)display
{
	[self browseURL:aURL andDisplay:display jump:YES];
}

- (void)browseURL:(NSURL *)aURL
{
	[self browseURL:aURL andDisplay:YES jump:YES];
}

#pragma mark -
#pragma mark ViJumpList delegate

- (void)jumpList:(ViJumpList *)aJumpList goto:(ViJump *)jump
{
	[self browseURL:[jump url] andDisplay:YES jump:NO];
}

- (void)jumpList:(ViJumpList *)aJumpList added:(ViJump *)jump
{
	DEBUG(@"added jump %@", jump);
}

/* syntax: [count]<ctrl-i> */
- (BOOL)jumplist_forward:(ViCommand *)command
{
	return [history forwardToURL:NULL line:NULL column:NULL view:NULL];
}

/* syntax: [count]<ctrl-o> */
- (BOOL)jumplist_backward:(ViCommand *)command
{
	NSUInteger zero = 0;
	NSView *view = nil;
	BOOL ok = [history backwardToURL:&rootURL line:&zero column:&zero view:&view];
	[pathControl setURL:rootURL];
	return ok;
}

#pragma mark -
#pragma mark Action menu

- (void)menuNeedsUpdate:(NSMenu *)menu
{
	[menu updateNormalModeMenuItemsWithSelection:NO];

	for (NSMenuItem *item in [menu itemArray]) {
		if ([item action] == @selector(rescan:)) {
			NSSet *parentSet = [self clickedFolderURLs];
			ViCommandMenuItemView *view = (ViCommandMenuItemView *)[item view];
			if ([view isKindOfClass:[ViCommandMenuItemView class]]) {
				if ([parentSet count] == 1)
					[view setTitle:[NSString stringWithFormat:@"Rescan folder \"%@\"", [[parentSet anyObject] lastPathComponent]]];
				else
					[view setTitle:[NSString stringWithFormat:@"Rescan folders"]];
				[item setTitle:view.title];
			}
		}
	}
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	__block BOOL fail = NO;

	NSIndexSet *set = [self clickedIndexes];

	if ([menuItem action] == @selector(openInTab:) ||
	    [menuItem action] == @selector(openInCurrentView:) ||
	    [menuItem action] == @selector(openInSplit:) ||
	    [menuItem action] == @selector(openInVerticalSplit:)) {
		/*
		 * Selected files must be files, not directories.
		 */
		[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
			id item = [explorer itemAtRow:idx];
			if (item == nil || [self outlineView:explorer isItemExpandable:item]) {
				*stop = YES;
				fail = YES;
			}
		}];
		if (fail)
			return NO;
	}

	/*
	 * Some items only operate on a single entry.
	 */
	if ([set count] > 1 &&
	   ([menuItem action] == @selector(openInCurrentView:) ||
	    [menuItem action] == @selector(renameFile:) ||
	    [menuItem action] == @selector(openInSplit:) ||		/* XXX: Splitting multiple documents is disabled for now, buggy */
	    [menuItem action] == @selector(openInVerticalSplit:)))
		return NO;

	/*
	 * Some items need at least one selected entry.
	 */
	if ([set count] == 0 && [explorer clickedRow] == -1 &&
	   ([menuItem action] == @selector(openInTab:) ||
	    [menuItem action] == @selector(openInCurrentView:) ||
	    [menuItem action] == @selector(openInSplit:) ||
	    [menuItem action] == @selector(openInVerticalSplit:) ||
	    [menuItem action] == @selector(renameFile:) ||
	    [menuItem action] == @selector(removeFiles:) ||
	    [menuItem action] == @selector(revealInFinder:) ||
	    [menuItem action] == @selector(openWithFinder:)))
		return NO;

	/*
	 * Finder operations only implemented for file:// urls.
	 */
	ViFile *file = [self fileForItem:[explorer itemAtRow:[set firstIndex]]];
	if (![file.url isFileURL] &&
	    ([menuItem action] == @selector(revealInFinder:) ||
	     [menuItem action] == @selector(openWithFinder:)))
		return NO;

	if ([menuItem action] == @selector(rescan:)) {
		if ([[self clickedFolderURLs] count] == 0)
			return NO;
	}

	/*
	 * Some operations not applicable in filtered list.
	 */
	if (isFiltered &&
	    ([menuItem action] == @selector(rescan:) ||
	     [menuItem action] == @selector(addSFTPLocation:) ||
	     [menuItem action] == @selector(newFolder:) ||
	     [menuItem action] == @selector(newDocument:)))
		return NO;

	return YES;
}


- (IBAction)actionMenu:(id)sender
{
	NSPoint p = NSMakePoint(0, 0);
	NSIndexSet *set = [explorer selectedRowIndexes];
	if ([set count] > 0)
		p = [explorer rectOfRow:[set firstIndex]].origin;
	NSEvent *ev = [NSEvent mouseEventWithType:NSLeftMouseDown
	                                 location:[explorer convertPoint:p toView:nil]
	                            modifierFlags:0
	                                timestamp:1
	                             windowNumber:[window windowNumber]
	                                  context:[NSGraphicsContext currentContext]
	                              eventNumber:1
	                               clickCount:1
	                                 pressure:0.0];
	[NSMenu popUpContextMenu:actionMenu withEvent:ev forView:sender];
}

/* Takes a string of characters and creates a macro of it.
 * Then feeds it into the key manager.
 */
- (BOOL)input:(NSString *)inputString
{
	NSArray *keys = [inputString keyCodes];
	if (keys == nil) {
		INFO(@"invalid key sequence: %@", inputString);
		return NO;
	}

	BOOL interactive = (window != nil);
	return [explorer.keyManager runAsMacro:inputString interactively:interactive];
}

- (IBAction)performNormalModeMenuItem:(id)sender
{
	if (explorer.keyManager.parser.partial) {
		[[[window windowController] nextRunloop] message:@"Vi command interrupted."];
		[explorer.keyManager.parser reset];
	}

	ViCommandMenuItemView *view = (ViCommandMenuItemView *)[sender view];
	if (view) {
		NSString *command = view.command;
		if (command) {
			DEBUG(@"performing command: %@", command);
			[self input:command];
		}
	}
}

#pragma mark -
#pragma mark Explorer actions

- (void)sftpSheetDidEnd:(NSWindow *)sheet
             returnCode:(int)returnCode
            contextInfo:(void *)contextInfo
{
	[sheet orderOut:self];
}

- (IBAction)acceptSftpSheet:(id)sender
{
	if ([[[sftpConnectForm cellAtIndex:0] stringValue] length] == 0) {
		NSBeep();
		[sftpConnectForm selectTextAtIndex:0];
		return;
	}
	[NSApp endSheet:sftpConnectView];
	NSString *host = [[sftpConnectForm cellAtIndex:0] stringValue];
	NSString *user = [[sftpConnectForm cellAtIndex:1] stringValue];	/* might be blank */
	NSString *path = [[sftpConnectForm cellAtIndex:2] stringValue];

	if (![path hasPrefix:@"/"])
		path = [NSString stringWithFormat:@"/~/%@", path];
	NSURL *url;
	path = [path stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
	if ([user length] > 0)
		url = [NSURL URLWithString:[NSString stringWithFormat:@"sftp://%@@%@%@", user, host, path]];
	else
		url = [NSURL URLWithString:[NSString stringWithFormat:@"sftp://%@%@", host, path]];
	[self browseURL:url];
}

- (IBAction)cancelSftpSheet:(id)sender
{
	[NSApp endSheet:sftpConnectView];
}

- (IBAction)addSFTPLocation:(id)sender
{
	[NSApp beginSheet:sftpConnectView
	   modalForWindow:window
	    modalDelegate:self
	   didEndSelector:@selector(sftpSheetDidEnd:returnCode:contextInfo:)
	      contextInfo:nil];
}

- (NSIndexSet *)clickedIndexes
{
	NSIndexSet *set = [explorer selectedRowIndexes];
	NSInteger clickedRow = [explorer clickedRow];
	if (clickedRow != -1 && ![set containsIndex:clickedRow])
		set = [NSIndexSet indexSetWithIndex:clickedRow];
	return set;
}

- (IBAction)openDocuments:(id)sender
{
	__block BOOL didOpen = NO;
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		if (file && !file.isDirectory) {
			[delegate gotoURL:file.targetURL];
			didOpen = YES;
		}
	}];

	if (didOpen)
		[self cancelExplorer];
}

- (IBAction)openInTab:(id)sender
{
	__block BOOL didOpen = NO;
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		if (file && !file.isDirectory) {
			NSError *err = nil;
			ViDocument *doc = [[ViDocumentController sharedDocumentController] openDocumentWithContentsOfURL:file.targetURL
														 display:NO
														   error:&err];
			if (err)
				[windowController message:@"%@: %@", file.url, [err localizedDescription]];
			else if (doc) {
				[windowController createTabForDocument:doc];
				didOpen = YES;
			}
		}
	}];

	if (didOpen)
		[self cancelExplorer];
}

- (IBAction)openInCurrentView:(id)sender
{
	NSUInteger idx = [[self clickedIndexes] firstIndex];
	id item = [explorer itemAtRow:idx];
	if (item == nil || [self outlineView:explorer isItemExpandable:item])
		return;
	ViFile *file = [self fileForItem:item];
	if (!file)
		return;
	NSError *err = nil;
	ViDocument *doc = [[ViDocumentController sharedDocumentController] openDocumentWithContentsOfURL:file.targetURL
												 display:NO
												   error:&err];

	if (err)
		[windowController message:@"%@: %@", file.url, [err localizedDescription]];
	else if (doc)
		[windowController switchToDocument:doc];
	[self cancelExplorer];
}

- (IBAction)openInSplit:(id)sender
{
	__block BOOL didOpen = NO;
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		if (file && !file.isDirectory) {
			[windowController splitVertically:NO
						  andOpen:file.url
				       orSwitchToDocument:nil];
			didOpen = YES;
		}
	}];

	if (didOpen)
		[self cancelExplorer];
}

- (IBAction)openInVerticalSplit:(id)sender;
{
	__block BOOL didOpen = NO;
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		if (file && !file.isDirectory) {
			[windowController splitVertically:YES
						  andOpen:file.url
				       orSwitchToDocument:nil];
			didOpen = YES;
		}
	}];

	if (didOpen)
		[self cancelExplorer];
}

- (IBAction)renameFile:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	NSInteger row = [set firstIndex];
	id item = [explorer itemAtRow:row];
	if (item == nil)
		return;
	if (isFiltered) {
		[self resetExplorerView];
		item = [item representedObject];
	}
	row = [explorer rowForItem:item];
	if (row != -1) {
		[self selectItemAtRow:row];
		[explorer editColumn:0 row:row withEvent:nil select:YES];
	}
}

- (void)deletedOpenDocumentsAlertDidEnd:(NSAlert *)alert
			     returnCode:(NSInteger)returnCode
			    contextInfo:(void *)contextInfo
{
	NSMutableSet *openDocs = contextInfo; // object survived because we also stored a strong reference in contextObjects

	if (returnCode != NSAlertFirstButtonReturn) {
		for (ViDocument *doc in openDocs)
			[doc closeAndWindow:NO];
	}

	[contextObjects removeObject:openDocs];
}

- (void)removeAlertDidEnd:(NSAlert *)alert
               returnCode:(NSInteger)returnCode
              contextInfo:(void *)contextInfo
{
	NSMutableArray *urls = contextInfo; // object survived because we also stored a strong reference in contextObjects

	if (returnCode != NSAlertFirstButtonReturn) {
		[contextObjects removeObject:urls];
		return;
	}

	[[ViURLManager defaultManager] removeItemsAtURLs:urls onCompletion:^(NSError *error) {
		if (error != nil)
			[NSApp presentError:error];

		NSMutableSet *set = [NSMutableSet set];
		NSMutableSet *openDocs = [NSMutableSet set];
		for (NSURL *url in urls) {
			id item = [self findItemWithURL:url];
			id parent = [explorer parentForItem:item];
			if (parent == nil)
				[set addObject:rootURL];
			else
				[set addObject:[[self fileForItem:parent] url]];

			ViDocumentController *docController = [ViDocumentController sharedDocumentController];
			ViDocument *doc = [docController documentForURLQuick:url];
			if (doc)
				[openDocs addObject:doc];
		}

		for (NSURL *url in set)
			[[ViURLManager defaultManager] notifyChangedDirectoryAtURL:url];

		if (isFiltered)
			[self resetExplorerView];
		[self cancelExplorer];

		for (ViDocument *doc in openDocs) {
			[doc updateChangeCount:NSChangeReadOtherContents];
			doc.isTemporary = YES;
		}

		NSUInteger nopen = [openDocs count];
		if (nopen > 0) {
			const char *pluralS = (nopen == 1 ? "" : "s");
			NSAlert *alert = [[NSAlert alloc] init];
			[alert setMessageText:[NSString stringWithFormat:@"Do you want to keep the deleted document%s open?", pluralS]];
			[alert addButtonWithTitle:[NSString stringWithFormat:@"Keep document%s open", pluralS]];
			[alert addButtonWithTitle:[NSString stringWithFormat:@"Close deleted document%s", pluralS]];
			[alert setInformativeText:[NSString stringWithFormat:@"%lu open document%s was deleted. Any unsaved changes will be lost if the document%s %s closed.", nopen, pluralS, pluralS, nopen == 1 ? "is" : "are"]];
			[alert setAlertStyle:NSWarningAlertStyle];

			[contextObjects addObject:openDocs];
			[alert beginSheetModalForWindow:window
					  modalDelegate:self
					 didEndSelector:@selector(deletedOpenDocumentsAlertDidEnd:returnCode:contextInfo:)
					    contextInfo:openDocs];

		}
	}];

	[contextObjects removeObject:urls];
}

- (IBAction)removeFiles:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	NSInteger nselected = [set count];

	NSMutableArray *urls = [[NSMutableArray alloc] init];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		[urls addObject:file.url];
	}];

	if ([urls count] == 0)
		return;

	BOOL isLocal = [rootURL isFileURL];
	char *pluralS = (nselected == 1 ? "" : "s");

	NSAlert *alert = [[NSAlert alloc] init];
	if (isLocal)
		[alert setMessageText:[NSString stringWithFormat:@"Do you want to move the selected file%s to the trash?", pluralS]];
	else
		[alert setMessageText:[NSString stringWithFormat:@"Do you want to permanently delete the selected file%s?", pluralS]];
	[alert addButtonWithTitle:@"OK"];
	[alert addButtonWithTitle:@"Cancel"];
	if (isLocal) {
		[alert setInformativeText:[NSString stringWithFormat:@"%lu file%s will be moved to the trash.", nselected, pluralS]];
		[alert setAlertStyle:NSWarningAlertStyle];
	} else {
		[alert setInformativeText:[NSString stringWithFormat:@"%lu file%s will be deleted immediately. This operation cannot be undone!", nselected, pluralS]];
		[alert setAlertStyle:NSCriticalAlertStyle];
	}

	[contextObjects addObject:urls];
	[alert beginSheetModalForWindow:window
			  modalDelegate:self
			 didEndSelector:@selector(removeAlertDidEnd:returnCode:contextInfo:)
			    contextInfo:urls];
}

- (NSSet *)clickedURLs
{
	NSMutableSet *urlSet = [NSMutableSet set];
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		[urlSet addObject:file.targetURL];
	}];

	return urlSet;
}

- (NSSet *)clickedFiles
{
	NSMutableSet *fileSet = [NSMutableSet set];
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		[fileSet addObject:file];
	}];

	return fileSet;
}

- (NSSet *)clickedFolderURLs
{
	NSMutableSet *parentSet = [NSMutableSet set];
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];

		if (!file.isDirectory)
			file = [explorer parentForItem:file];

		NSURL *parent;
		if (file)
			parent = file.url;
		else
			parent = rootURL;

		[parentSet addObject:parent];
	}];

	return parentSet;
}

- (IBAction)rescan:(id)sender
{
	for (NSURL *parent in [self clickedFolderURLs])
		[self rescanURL:parent];
}

- (IBAction)flushCache:(id)sender
{
	[[ViURLManager defaultManager] flushDirectoryCache];
	[self browseURL:rootURL andDisplay:YES jump:NO];
}

- (IBAction)revealInFinder:(id)sender
{
	NSMutableArray *urls = [[NSMutableArray alloc] init];
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		[urls addObject:file.url];
	}];
	[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
}

- (IBAction)openWithFinder:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		id item = [explorer itemAtRow:idx];
		ViFile *file = [self fileForItem:item];
		[[NSWorkspace sharedWorkspace] openURL:file.url];
	}];
}

- (IBAction)newDocument:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	NSURL *parent = nil;
	if ([set count] == 1) {
		ViFile *file = [explorer itemAtRow:[set firstIndex]];
		if (file.isDirectory)
			parent = file.url;
		else
			parent = [[explorer parentForItem:file] url];
	}

	if (parent == nil)
		parent = rootURL;

	NSURL *newURL = [parent URLByAppendingPathComponent:@"New File"];
	[[ViURLManager defaultManager] writeDataSafely:[NSData data]
						 toURL:newURL
					  onCompletion:^(NSURL *url, NSDictionary *attrs, NSError *error) {
		if (error)
			[NSApp presentError:error];
		else
			[self rescanURL:parent onlyIfCached:NO andRenameURL:url];
	}];
}

- (IBAction)newFolder:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	NSURL *parent = nil;
	if ([set count] == 1) {
		ViFile *file = [explorer itemAtRow:[set firstIndex]];
		if (file.isDirectory)
			parent = file.url;
		else
			parent = [[explorer parentForItem:file] url];
	}

	if (parent == nil)
		parent = rootURL;

	NSURL *newURL = [parent URLByAppendingPathComponent:@"New Folder"];
	[[ViURLManager defaultManager] createDirectoryAtURL:newURL
					       onCompletion:^(NSError *error) {
		if (error)
			[NSApp presentError:error];
		else
			[self rescanURL:parent onlyIfCached:NO andRenameURL:newURL];
	}];
}

- (IBAction)bookmarkFolder:(id)sender
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSArray *bookmarks = [defaults arrayForKey:@"bookmarks"];
	NSString *url = [rootURL absoluteString];
	if (![bookmarks containsObject:url]) {
		if (bookmarks == nil)
			bookmarks = [NSArray arrayWithObject:@"dummy"];
		[defaults setObject:[bookmarks arrayByAddingObject:url] forKey:@"bookmarks"];
	}
}

- (IBAction)gotoBookmark:(id)sender
{
	NSURL *url = [NSURL URLWithString:[sender titleOfSelectedItem]];
	[self browseURL:url];
}

- (void)resetExplorerView
{
	[filterField setStringValue:@""];
	[altFilterField setStringValue:@""];
	[self hideAltFilterField];
	[self filterFiles:self];
}

- (void)explorerClick:(id)sender
{
	if ([[NSApp currentEvent] modifierFlags] & NSCommandKeyMask)
		return;

	NSIndexSet *set = [explorer selectedRowIndexes];

	if ([set count] == 0) {
		[self selectItemAtRow:lastSelectedRow];
		return;
	}

	if ([set count] > 1)
		return;

	id item = [explorer itemAtRow:[set firstIndex]];
	if (item == nil)
		return;

	if ([self outlineView:explorer isItemExpandable:item])
		return;

	/* Open in splits instead if alt key pressed. */
	if ([[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask)
		[self openInSplit:sender];
	else
		[self openDocuments:sender];
}

- (void)explorerDoubleClick:(id)sender
{
	NSIndexSet *set = [explorer selectedRowIndexes];
	if ([set count] > 1)
		return;
	id item = [explorer itemAtRow:[set firstIndex]];
	ViFile *file = [self fileForItem:item];
	if (file.isDirectory) {
		[self browseURL:file.targetURL];
		[self selectItemAtRow:0];
	} else
		[self explorerClick:sender];
}

#if 0

- (void)showAltFilterField
{
	if ([altFilterField isHidden]) {
		isHidingAltFilterField = NO;
		[NSAnimationContext beginGrouping];
		[[NSAnimationContext currentContext] setDuration:0.1];

		NSRect explorerFrame = [explorerView frame];

		NSRect frame = [scrollView frame];
		frame.size.height = explorerFrame.size.height - 23 - 25;
		[[scrollView animator] setFrame:frame];

		[altFilterField setFrame:NSMakeRect(1, explorerFrame.size.height - 2, explorerFrame.size.width - 2, 0)];
		[altFilterField setHidden:NO];
		[[altFilterField animator] setFrame:NSMakeRect(1, explorerFrame.size.height - 24, explorerFrame.size.width - 2, 22)];

		CAAnimation *animation = [altFilterField animationForKey:@"frameOrigin"];
		animation.delegate = self;

		[NSAnimationContext endGrouping];
	}
}

- (void)animationDidStop:(CAAnimation *)theAnimation finished:(BOOL)flag
{
	if (flag) {
		if (isHidingAltFilterField)
			[altFilterField setHidden:YES];
		else {
			NSRect explorerFrame = [explorerView frame];
			[altFilterField setFrame:NSMakeRect(1, explorerFrame.size.height - 24, explorerFrame.size.width - 2, 22)];
			[[altFilterField cell] calcDrawInfo:[altFilterField frame]];
		}
	}
}

- (void)hideAltFilterField
{
	if (![altFilterField isHidden]) {
		isHidingAltFilterField = YES;
		[NSAnimationContext beginGrouping];
		[[NSAnimationContext currentContext] setDuration:0.1];

		NSRect explorerFrame = [explorerView frame];

		NSRect frame = [scrollView frame];
		frame.size.height = explorerFrame.size.height - 24;
		[[scrollView animator] setFrame:frame];

		NSRect altFrame = [altFilterField frame];
		altFrame.size.height = 0;
		altFrame.origin = NSMakePoint(1, explorerFrame.size.height - 2);
		[[altFilterField animator] setFrame:altFrame];

		CAAnimation *animation = [altFilterField animationForKey:@"frameOrigin"];
		animation.delegate = self;

		[NSAnimationContext endGrouping];
	}
}

#else

- (void)showAltFilterField
{
	if ([altFilterField isHidden]) {
		NSRect explorerFrame = [explorerView frame];
		NSRect frame = [scrollView frame];
		frame.size.height = explorerFrame.size.height - 23 - 22 - 3;
		[scrollView setFrame:frame];
		[altFilterField setHidden:NO];
	}
}

- (void)hideAltFilterField
{
	if (![altFilterField isHidden]) {
		NSRect explorerFrame = [explorerView frame];
		NSRect frame = [scrollView frame];
		frame.size.height = explorerFrame.size.height - 23;
		[scrollView setFrame:frame];
		[altFilterField setHidden:YES];
	}
}

#endif

- (IBAction)searchFiles:(id)sender
{
	NSToolbar *toolbar = [window toolbar];
	if (![(ViWindow *)window isFullScreen] && [toolbar isVisible] && [[toolbar items] containsObject:searchToolbarItem]) {
		[window makeFirstResponder:filterField];
	} else {
		[self showAltFilterField];
		[window makeFirstResponder:altFilterField];
	}
}

- (void)firstResponderChanged:(NSNotification *)notification
{
	NSView *view = [notification object];
	if (view == filterField || view == altFilterField)
		[self openExplorerTemporarily:YES];
	else if ([view isKindOfClass:[NSView class]] && ![view isDescendantOf:explorerView]) {
		if ([view isKindOfClass:[NSTextView class]] && [(NSTextView *)view isFieldEditor])
			return;
		if (closeExplorerAfterUse) {
			[self closeExplorerAndFocusEditor:NO];
			closeExplorerAfterUse = NO;
		}
		[self hideAltFilterField];
	}

	if ([explorer selectedRow] != -1)
		lastSelectedRow = [explorer selectedRow];
}

- (BOOL)explorerIsOpen
{
	return ![splitView isSubviewCollapsed:explorerView];
}

- (void)openExplorerTemporarily:(BOOL)temporarily
{
	if (rootURL == nil)
		[self browseURL:windowController.baseURL andDisplay:NO];

	if (![self explorerIsOpen]) {
		if (temporarily)
			closeExplorerAfterUse = YES;
		[splitView setPosition:width ofDividerAtIndex:0];
	}
}

- (void)closeExplorerAndFocusEditor:(BOOL)focusEditor
{
	width = [explorerView frame].size.width;
	[splitView setPosition:0.0 ofDividerAtIndex:0];
	if (focusEditor)
		[delegate focusEditor];
}

- (IBAction)toggleExplorer:(id)sender
{
	if ([self explorerIsOpen])
		[self closeExplorerAndFocusEditor:NO];
	else
		[self openExplorerTemporarily:NO];
}

- (IBAction)focusExplorer:(id)sender
{
	[self openExplorerTemporarily:YES];
	[window makeFirstResponder:explorer];

	[self selectItemAtRow:lastSelectedRow];
	[explorer scrollRowToVisible:lastSelectedRow];
}

- (void)cancelExplorer
{
	lastSelectedRow = [explorer selectedRow];
	[delegate focusEditorDelayed:nil];
	if (closeExplorerAfterUse) {
		[self closeExplorerAndFocusEditor:YES];
		closeExplorerAfterUse = NO;
	}
	[self resetExplorerView];
}

- (void)expandItems:(NSArray *)items
{
	[self expandItems:items recursionLimit:3];

	if (isFiltering)
		[filteredItems sortUsingComparator:^(id a, id b) {
			ViCompletion *ca = a, *cb = b;
			if (ca.score > cb.score)
				return (NSComparisonResult)NSOrderedAscending;
			else if (cb.score > ca.score)
				return (NSComparisonResult)NSOrderedDescending;
			return (NSComparisonResult)NSOrderedSame;
			}];

	[explorer reloadData];
	if ([itemsToFilter count] > 0)
		[[self nextRunloop] expandNextItem];
}

- (void)expandNextItem
{
	if (!isFiltering || [itemsToFilter count] == 0)
		return;

	ViFile *file = [itemsToFilter objectAtIndex:0];
	[itemsToFilter removeObjectAtIndex:0];

	if ([file hasCachedChildren]) {
		[self expandItems:file.children];
		return;
	}

	[self childrenAtURL:file.targetURL onCompletion:^(NSMutableArray *children, NSError *error) {
		if (error) {
			/* schedule re-read of parent folder */
			ViFile *parent = [explorer parentForItem:file];
			if (parent) {
				DEBUG(@"scheduling re-read of parent item %@", parent);
				[itemsToFilter addObject:parent];
			} else
				DEBUG(@"no parent for item %@", file);
		} else {
			file.children = children;
			DEBUG(@"expanding children of item %@", file);
			[self expandItems:file.children];
		}
	}];
}

- (void)expandItems:(NSArray *)items recursionLimit:(int)recursionLimit
{
	NSString *base = [rootURL path];
	NSUInteger prefixLength = [base length];
	if (![base hasSuffix:@"/"])
		prefixLength++;

	for (ViFile *file in items) {
		DEBUG(@"got file %@", file);
		if (file.isDirectory) {
			if (recursionLimit > 0 && [file hasCachedChildren]) {
				DEBUG(@"expanding children of item %@", file);
				[self expandItems:file.children recursionLimit:recursionLimit - 1];
			} else
				/* schedule in runloop */
				[itemsToFilter addObject:file];
		} else {
			ViRegexpMatch *m = nil;
			NSString *p = [file.path substringFromIndex:prefixLength];
			if (rx == nil || (m = [rx matchInString:p]) != nil) {
				ViCompletion *c = [ViCompletion completionWithContent:p fuzzyMatch:m];
				c.font = font;
				c.representedObject = file;
				c.markColor = [NSColor blackColor];
				[filteredItems addObject:c];
			}
		}
	}
}

- (void)appendFilter:(NSString *)string
           toPattern:(NSMutableString *)pattern
          fuzzyClass:(NSString *)fuzzyClass
{
	NSUInteger i;
	for (i = 0; i < [string length]; i++) {
		unichar c = [string characterAtIndex:i];
		if (i != 0)
			[pattern appendFormat:@"%@*?", fuzzyClass];
		if (c == ' ')
			[pattern appendString:@"(\\W*?)"];
		else
			[pattern appendFormat:@"(%s%C)", [ViRegexp needEscape:c] ? "\\" : "", c];
	}
}

- (IBAction)filterFiles:(id)sender
{
	NSString *filter;
	if ([altFilterField isHidden])
		filter = [filterField stringValue];
	else
		filter = [altFilterField stringValue];

	if ([filter length] == 0) {
		isFiltered = NO;
		isFiltering = NO;
		filteredItems = [NSMutableArray arrayWithArray:rootItems];
		[explorer reloadData];
		[self resetExpandedItems];
		[explorer selectRowIndexes:[NSIndexSet indexSet]
		      byExtendingSelection:NO];
	} else {
		NSMutableString *pattern = [NSMutableString string];
		[pattern appendFormat:@"^.*"];
		[self appendFilter:filter toPattern:pattern fuzzyClass:@"[^/]"];
		[pattern appendString:@"[^/]*$"];

		rx = [[ViRegexp alloc] initWithString:pattern
					      options:ONIG_OPTION_IGNORECASE];

		filteredItems = [NSMutableArray array];
		itemsToFilter = [NSMutableArray array];
		isFiltered = YES;
		isFiltering = YES;

		[self expandItems:rootItems];
		[self selectItemAtRow:0];
	}
}

#pragma mark -

- (BOOL)control:(NSControl *)sender
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)aSelector
{
	if ([self isEditing]) {
		if (aSelector == @selector(cancelOperation:)) { // escape
			[explorer abortEditing];
			[window makeFirstResponder:explorer];
			return YES;
		}
		return NO;
	}

	if (aSelector == @selector(insertNewline:)) { // enter
		NSIndexSet *set = [explorer selectedRowIndexes];
		if ([set count] == 0)
			[self cancelExplorer];
		else
			[self explorerClick:sender];
		return YES;
	} else if (aSelector == @selector(moveUp:)) { // up arrow
		NSInteger row = [explorer selectedRow];
		if (row > 0)
			[self selectItemAtRow:row - 1];
		return YES;
	} else if (aSelector == @selector(moveDown:)) { // down arrow
		NSInteger row = [explorer selectedRow];
		if (row + 1 < [explorer numberOfRows])
			[self selectItemAtRow:row + 1];
		return YES;
	} else if (aSelector == @selector(cancelOperation:)) { // escape
		isFiltering = NO;
		if (isFiltered) {
			[window makeFirstResponder:explorer];
			/* make sure something is selected */
			if ([explorer selectedRow] == -1)
				[self selectItemAtRow:0];
		} else
			[self cancelExplorer];
		return YES;
	}

	return NO;
}

#pragma mark -
#pragma mark Explorer Command Parser

- (BOOL)show_menu:(ViCommand *)command
{
	[self actionMenu:explorer];
	return YES;
}

- (BOOL)find:(ViCommand *)command
{
	[self searchFiles:nil];
	return YES;
}

- (BOOL)cancel_or_reset:(ViCommand *)command
{
	if (isFiltered)
		[self resetExplorerView];
	else
		[self cancelExplorer];
	return YES;
}

- (BOOL)cancel:(ViCommand *)command
{
	[self cancelExplorer];
	return YES;
}

- (BOOL)switch_open:(ViCommand *)command
{
	[self openInCurrentView:nil];
	return YES;
}

- (BOOL)split_open:(ViCommand *)command
{
	[self openInSplit:nil];
	return YES;
}

- (BOOL)vsplit_open:(ViCommand *)command
{
	[self openInVerticalSplit:nil];
	return YES;
}

- (BOOL)tab_open:(ViCommand *)command
{
	[self openInTab:nil];
	return YES;
}

- (BOOL)open:(ViCommand *)command
{
	[self explorerDoubleClick:nil];
	return YES;
}

- (void)resetExpandedItems:(NSArray *)items
{
	if (isFiltered)
		return;

	for (ViFile *file in items) {
		if (file.isDirectory) {
			if ([expandedSet containsObject:file.url])
				[explorer expandItem:file];
			if ([file hasCachedChildren])
				[self resetExpandedItems:file.children];
		}
	}
}

- (void)resetExpandedItems
{
	[self resetExpandedItems:rootItems];
}

- (id)findItemWithURL:(NSURL *)aURL inItems:(NSArray *)items
{
	for (id item in items) {
		ViFile *file = [self fileForItem:item];
		if ([file.url isEqualToURL:aURL] || [file.targetURL isEqualToURL:aURL])
			return item;
		if (file.isDirectory && [file hasCachedChildren]) {
			id foundItem = [self findItemWithURL:aURL inItems:file.children];
			if (foundItem)
				return foundItem;
		}
	}

	return nil;
}

- (id)findItemWithURL:(NSURL *)aURL
{
	if (isFiltered)
		return [self findItemWithURL:aURL inItems:filteredItems];
	else
		return [self findItemWithURL:aURL inItems:rootItems];
}

- (NSInteger)rowForItemWithURL:(NSURL *)aURL
{
	id item = [self findItemWithURL:aURL];
	if (item == nil)
		return -1;
	NSURL *parentURL = [[self fileForItem:item].url URLByDeletingLastPathComponent];
	if (parentURL && ![parentURL isEqualToURL:rootURL]) {
		NSInteger parentRow = [self rowForItemWithURL:parentURL];
		if (parentRow != -1)
			[explorer expandItem:[explorer itemAtRow:parentRow]];
	}
	return [explorer rowForItem:item];
}

- (BOOL)selectItemAtRow:(NSInteger)row
{
	if (row == -1)
		return NO;
	[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
	      byExtendingSelection:NO];
	[explorer scrollRowToVisible:row];

	return YES;
}

- (BOOL)selectItem:(id)item
{
	NSInteger row = [explorer rowForItem:item];
	if (row == -1)
		return NO;
	[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
	      byExtendingSelection:NO];
	return YES;
}

- (BOOL)selectItemWithURL:(NSURL *)aURL
{
	return [self selectItemAtRow:[self rowForItemWithURL:aURL]];
}

- (BOOL)displaysURL:(NSURL *)aURL
{
	return [rootURL isEqualToURL:aURL] ||
	       [self findItemWithURL:aURL] != nil;
}

- (void)URLContentsWasCached:(NSNotification *)notification
{
	NSURL *url = [[notification userInfo] objectForKey:@"URL"];

	if (isExpandingTree || [self isEditing]) {
		DEBUG(@"ignoring changes to directory %@", url);
		return;
	}

	ViURLManager *urlman = [ViURLManager defaultManager];
	NSArray *contents = [urlman cachedContentsOfDirectoryAtURL:url];
	if (contents == nil) {
		DEBUG(@"huh? cached contents of %@ gone already!?", url);
		return;
	}

	if (rootURL && ![url hasPrefix:rootURL]) {
		DEBUG(@"changed URL %@ currently not shown in this explorer, ignoring", url);
		return;
	}

	NSMutableSet *selectedURLs = [NSMutableSet set];
	if (!isFiltered || isFiltering) {
		NSIndexSet *selectedIndices = [explorer selectedRowIndexes];
		[selectedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
			id item = [explorer itemAtRow:idx];
			ViFile *file = [self fileForItem:item];
			if (file)
				[selectedURLs addObject:file.url];
		}];
	}

	DEBUG(@"updating contents of %@", url);
	NSMutableArray *children = [self filteredContents:contents ofDirectory:url];

	id item = [self findItemWithURL:url];
	if (item) {
		ViFile *file = [self fileForItem:item];
		file.children = children;
	} else if ([url isEqualToURL:rootURL]) {
		rootItems = children;
		if (!isFiltered || isFiltering)
			[self filterFiles:self];
	} else {
		DEBUG(@"URL %@ not displayed in this explorer (root is %@)", url, rootURL);
		return;
	}

	[[ViEventManager defaultManager] emit:ViEventExplorerURLUpdated for:self with:self, url, nil];

	[explorer reloadData];
	[self resetExpandedItems];

	if ([selectedURLs count] > 0) {
		NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
		for (NSURL *url in selectedURLs)
			[set addIndex:[self rowForItemWithURL:url]];
		[explorer selectRowIndexes:set byExtendingSelection:NO];
		[explorer scrollRowToVisible:[set lastIndex]];
		[explorer scrollRowToVisible:[set firstIndex]];
	}
}

- (void)rescanURL:(NSURL *)aURL
     onlyIfCached:(BOOL)cacheFlag
     andRenameURL:(NSURL *)renameURL
{
	ViURLManager *urlman = [ViURLManager defaultManager];

	if (cacheFlag) {
		if (![urlman directoryIsCachedAtURL:aURL]) {
			DEBUG(@"changed URL %@ is not cached", aURL);
			return;
		}
		if (![aURL hasPrefix:rootURL]) {
			DEBUG(@"changed URL %@ currently not shown in explorer, flushing cache", aURL);
			[urlman flushCachedContentsOfDirectoryAtURL:aURL];
			return;
		}
	}

	NSURL *selectedURL = renameURL;
	if (selectedURL == nil) {
		id selectedItem = [explorer itemAtRow:[explorer selectedRow]];
		ViFile *selectedFile = [self fileForItem:selectedItem];
		selectedURL = selectedFile.url;
	}

	[urlman flushCachedContentsOfDirectoryAtURL:aURL];
	[self childrenAtURL:aURL onCompletion:^(NSMutableArray *children, NSError *error) {
		if (error && ![error isFileNotFoundError]) {
			NSAlert *alert = [NSAlert alertWithError:error];
			[alert runModal];
		} else {
			/* The notification should already have reloaded the data. */
			[explorer expandItem:[self findItemWithURL:aURL]];

			if (renameURL) {
				id item = [self findItemWithURL:renameURL];
				if (item) {
					NSInteger row = [explorer rowForItem:item];
					[self selectItemAtRow:row];
					[explorer editColumn:0 row:row withEvent:nil select:YES];
				}
			} else if (selectedURL) {
				[self selectItemWithURL:selectedURL];
			}
		}
	}];
}

- (void)rescanURL:(NSURL *)aURL
{
	[self rescanURL:aURL onlyIfCached:YES andRenameURL:nil];
}

- (BOOL)rescan_files:(ViCommand *)command
{
	[self rescan:nil];
	return YES;
}

- (BOOL)new_document:(ViCommand *)command
{
	[self newDocument:nil];
	return YES;
}

- (BOOL)new_folder:(ViCommand *)command
{
	[self newFolder:nil];
	return YES;
}

- (BOOL)rename_file:(ViCommand *)command
{
	[self renameFile:nil];
	return YES;
}

- (BOOL)remove_files:(ViCommand *)command
{
	[self removeFiles:nil];
	return YES;
}

- (BOOL)keyManager:(ViKeyManager *)keyManager
   evaluateCommand:(ViCommand *)command
{
	DEBUG(@"command is %@", command);
	id target;
	if ([explorer respondsToSelector:command.action])
		target = explorer;
	else if ([self respondsToSelector:command.action])
		target = self;
	else {
		[windowController message:@"Command not implemented."];
		return NO;
	}

	return (BOOL)[target performSelector:command.action withObject:command];
}

#pragma mark -
#pragma mark Explorer Outline View Delegate

- (void)outlineViewItemWillExpand:(NSNotification *)notification
{
	id item = [[notification userInfo] objectForKey:@"NSObject"];
	ViFile *file = [self fileForItem:item];
	if ([file hasCachedChildren])
		return;

	__block BOOL directoryContentsIsAsync = NO;
	isExpandingTree = YES;
	[self childrenAtURL:file.url onCompletion:^(NSMutableArray *children, NSError *error) {
		if (error)
			[NSApp presentError:error];
		else {
			file.children = children;
			if (directoryContentsIsAsync) {
				[explorer reloadData];
				[explorer expandItem:file];
			}
		}
	}];
	isExpandingTree = NO;
	directoryContentsIsAsync = YES;
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification
{
	id item = [[notification userInfo] objectForKey:@"NSObject"];
	ViFile *file = [self fileForItem:item];
	[expandedSet addObject:file.url];
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification
{
	id item = [[notification userInfo] objectForKey:@"NSObject"];
	ViFile *file = [self fileForItem:item];
	[expandedSet removeObject:file.url];
}

#pragma mark -
#pragma mark Explorer Outline View Data Source

- (void)outlineView:(NSOutlineView *)outlineView
     setObjectValue:(id)object
     forTableColumn:(NSTableColumn *)tableColumn
	     byItem:(id)item
{
	if (![object isKindOfClass:[NSString class]] || ![item isKindOfClass:[ViFile class]])
		return;

	ViFile *file = item;
	NSURL *parentURL = [file.url URLByDeletingLastPathComponent];
	NSURL *newurl = [[parentURL URLByAppendingPathComponent:object] URLByStandardizingPath];
	if ([file.url isEqualToURL:newurl])
		return;

	[[ViURLManager defaultManager] moveItemAtURL:file.url
					       toURL:newurl
					onCompletion:^(NSURL *normalizedURL, NSError *error) {
		if (error) {
			DEBUG(@"failed to rename %@: %@", file, error);
			[NSApp presentError:error];
			if ([error isFileNotFoundError])
				[[ViURLManager defaultManager] notifyChangedDirectoryAtURL:parentURL];
		} else {
			DEBUG(@"updating renamed file %@ with new url %@ (really %@)", file, newurl, normalizedURL);
			if (!file.isLink) {
				ViDocument *doc = [windowController documentForURL:file.targetURL];
				[doc setFileURL:normalizedURL];
			}
			[file setURL:newurl];
			[file setTargetURL:normalizedURL];
			[explorer reloadData];

			[[ViURLManager defaultManager] notifyChangedDirectoryAtURL:parentURL];
		}
	}];
}

- (id)outlineView:(NSOutlineView *)outlineView
            child:(NSInteger)anIndex
           ofItem:(id)item
{
	if (item == nil)
		return [filteredItems objectAtIndex:anIndex];

	ViFile *pf = [self fileForItem:item];
	if (![pf hasCachedChildren])
		return nil;
	return [pf.children objectAtIndex:anIndex];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
   isItemExpandable:(id)item
{
	ViFile *pf = [self fileForItem:item];
	return [pf isDirectory];
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView
  numberOfChildrenOfItem:(id)item
{
	if (item == nil)
		return [filteredItems count];

	ViFile *pf = [self fileForItem:item];
	if (![pf hasCachedChildren])
		return 0;
	return [pf.children count];
}

- (id)outlineView:(NSOutlineView *)outlineView
objectValueForTableColumn:(NSTableColumn *)tableColumn
           byItem:(id)item
{
	if ([item isKindOfClass:[ViCompletion class]])
		return [(ViCompletion *)item title];
	else
		return [(ViFile *)item displayName];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
        isGroupItem:(id)item
{
	return NO;
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView
     heightOfRowByItem:(id)item
{
	return 20;
}

- (void)setStatusImage:(NSImage *)image forURL:(NSURL *)url
{
	NSParameterAssert(image);
	NSParameterAssert(url);
	[statusImages setObject:image forKey:[url absoluteURL]];
	[explorer reloadData];
}

- (void)setStatusImages:(NSDictionary *)dictionary
{
	statusImages = [dictionary mutableCopy];
	[explorer reloadData];
}

- (void)clearStatusImages
{
	[statusImages removeAllObjects];
	[explorer reloadData];
}

- (NSCell *)outlineView:(NSOutlineView *)outlineView
 dataCellForTableColumn:(NSTableColumn *)tableColumn
                   item:(id)item
{
	ViDocumentController *docController = [ViDocumentController sharedDocumentController];
	NSInteger row = [explorer rowForItem:item];
	NSCell *cell = [tableColumn dataCellForRow:row];
	if (cell) {
		ViFile *file = [self fileForItem:item];
		ViDocument *doc = [docController documentForURLQuick:file.targetURL];
		[(MHTextIconCell *)cell setModified:[doc isDocumentEdited]];
		[(MHTextIconCell *)cell setStatusImage:[statusImages objectForKey:file.url]];
		[cell setFont:font];
		[cell setImage:[file icon]];
	}

	return cell;
}

- (void)documentEditedChanged:(NSNotification *)notification
{
	ViDocument *doc = [notification object];
	id item = [self findItemWithURL:[doc fileURL]];
	if (item) {
		NSInteger row = [explorer rowForItem:item];
		if (row != -1)
			[explorer reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
					    columnIndexes:[NSIndexSet indexSetWithIndex:0]];
	}
}

@end