#import "MyDocument.h"

#import <RegexKit/RegexKit.h>

#import "HacSavePanelAdditions.h"

#import "AppController.h"

@implementation MyDocument

#pragma mark -
#pragma mark Document Methods

- (NSString *)windowNibName
{
    return @"DownloadWindow";
}

- (void)windowControllerDidLoadNib:(NSWindowController *) aController
{
    [super windowControllerDidLoadNib:aController];
    [[locationBar window] setDelegate:self];
}

#pragma mark -
#pragma mark Progress Sheet

- (void)showLoadingSheet
// Show the progress indicator.
{
	[self bookProcessingStatusChanged:@"Loading book..."];
	
	[progressIndicator setUsesThreadedAnimation:YES];
	[progressIndicator startAnimation:nil];

	[NSApp beginSheet:[progressIndicator window]
	   modalForWindow:[locationBar window]
		modalDelegate:self
	   didEndSelector:nil
		  contextInfo:nil];
}

- (void)hideLoadingSheet
// Hide the progress indicator.
{
	[NSApp endSheet:[progressIndicator window]];
	[[progressIndicator window] orderOut:nil];

	[progressIndicator stopAnimation:nil];
}

#pragma mark -
#pragma mark Error Notifications

- (void)setErrorMessage:(NSString *)newErrorMessage
{
	[errorMessage release];
	errorMessage = [newErrorMessage retain];
}

- (void)setErrorInformation:(NSString *)newErrorInformation
{
	[errorInformation release];
	errorInformation = [newErrorInformation retain];
}

- (void)runAlertSheetForError
{
	[self hideLoadingSheet];

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert addButtonWithTitle:@"OK"];
	[alert setMessageText:errorMessage];
	[alert setInformativeText:errorInformation];
	[alert setAlertStyle:NSInformationalAlertStyle];
	[alert beginSheetModalForWindow:[locationBar window] modalDelegate:self didEndSelector:nil contextInfo:nil];
}

#pragma mark -
#pragma mark Window Delegate Methods

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize
{
	return NSMakeSize(frameSize.width, [sender frame].size.height);
}

#pragma mark -
#pragma mark Book Delegate Methods

- (void)bookProcessingDidFailWithMessageText:(NSString *)messageText
						  andInformativeText:(NSString *)informativeText
{
	[self setErrorMessage:messageText];
	[self setErrorInformation:informativeText];
	[self performSelectorOnMainThread:@selector(runAlertSheetForError) withObject:nil waitUntilDone:YES];
}

- (void)bookProcessingStatusChanged:(NSString *)statusText
{
	[progressLabel setStringValue:statusText];
}

- (NSProgressIndicator *)bookProcessingProgressIndicator
{
	return progressIndicator;
}

#pragma mark -
#pragma mark Downloading

- (void)cleanUpAfterDownload
// After a download ends, the document can be used again for another download.
// Reset member variables for the next download.
{
	userWantsToAbort = NO;

	if (book)
	{
		[book release];
		book = nil;
	}

	if (pdfDocument)
	{
		[pdfDocument release];
		pdfDocument = nil;
	}

	if (savePath)
	{
		[savePath release];
		savePath = nil;
	}

	[self hideLoadingSheet];
	[cancelButton setEnabled:YES];
}

- (NSString *)bookIdFromUserInput
{
	NSString *userInput = [locationBar stringValue];

	RKRegex *idPattern = [RKRegex regexWithRegexString:@"id=([^&]+)" options:RKCompileCaseless];

	// If it looks like the id is part of a URL...
	if ([userInput isMatchedByRegex:idPattern])
	{
		// Extract the ID argument.
		return [userInput stringByMatching:idPattern withReferenceString:@"${1}"];
	}

	// Otherwise, the ID is the whole user input string.
	return userInput;
}

- (IBAction)beginDownload:(id)sender
{
	NSString *userInput = [locationBar stringValue];
	
	[startPage setStringValue:@""];
	[pageLimit setStringValue:@""];

	// If the user hasn't put text in the location field, they probably clicked the button accidentally.
	if (![userInput length])
		return;

	// Make a book object to represent the book on Google Books.
	book = [[GoogleBook alloc] init];

	// The book will call delegate methods to indicate progress or errors (see the delegate methods above).
	[book setDelegate:self];
	
	// The user could have given us the URL or the Book ID. We want the Book ID no matter which one they gave us.
	[book setBookId:[self bookIdFromUserInput]];

	if ([[book bookId] rangeOfString:@"/"].location != NSNotFound)
	{
		[self bookProcessingDidFailWithMessageText:@"Bad URL"
								andInformativeText:@"This does not look like a Google Books URL!"];
		
		[self cleanUpAfterDownload];
		return;
		
	}
	if (![book bookExists])
	{
			[self bookProcessingDidFailWithMessageText:@"Bad Book ID"
									andInformativeText:@"I looked on Google Books for the book with that ID but I couldn't find it!"];

		[self cleanUpAfterDownload];
		return;
	}

	// Everything we have done at this point has been almost instantaneous, so we have done it on the main thread.
	// Now we need to do the longer tasks, so we will show the save sheet and then create a new thread.
	[self performSelectorOnMainThread:@selector(runSaveSheetWithFilename:)
						   withObject:[book bookTitle]
						waitUntilDone:YES];
}

- (IBAction)cancelDownload:(id)sender
{
	[cancelButton setEnabled:NO];

	userWantsToAbort = YES;
	[book abortProcedures];
}

- (void)savePDFDocumentAtPath:(NSString *)path
{
	NSAutoreleasePool *autoreleasePool = [[NSAutoreleasePool alloc] init];

	[progressIndicator setIndeterminate:YES];
	[progressIndicator startAnimation:nil];
	[progressLabel setStringValue:@"Saving PDF to disk..."];

	// The last time I tried to write it atomically was with a 136 page book and the file did not show up.
	/*bool saveSuccess = [[pdfDocument dataRepresentation] writeToFile:path
														  atomically:NO];*/
	bool saveSuccess = [pdfDocument writeToFile:path];
	
	if (!saveSuccess)
	{
		[self setErrorMessage:@"Couldn't Save PDF"];
		[self setErrorInformation:@"An unkown error occured while saving the PDF."];
		[self performSelectorOnMainThread:@selector(runAlertSheetForError) withObject:nil waitUntilDone:YES];
		return;
	}
	
	[autoreleasePool release];

}

- (void)download
{
	NSAutoreleasePool *autoreleasePool = [[NSAutoreleasePool alloc] init];
	
	[book setStartPage:[startPage stringValue]];
	[book setPageLimit:[pageLimit intValue]];
	
	[self performSelectorOnMainThread:@selector(showLoadingSheet) withObject:nil waitUntilDone:YES];

	if (saveAsFolder)
	{
		[book saveImagesToFolder:savePath];
	}
	else
	{
		// Collect all the images in a PDF document.
		pdfDocument = [[book pdfDocument] retain];
		
		if (pdfDocument)
		{
			// Write the PDF document to the disk.
			[self savePDFDocumentAtPath:savePath];
		}
	}
	
	[self performSelectorOnMainThread:@selector(hideLoadingSheet)
						   withObject:nil
						waitUntilDone:YES];
	
	// Open the book with the default application if the option is enabled in the preferences.
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"AutoOpenDownloadsInFinder"])
	{
		NSString *openPath = (saveAsFolder)?[savePath stringByAppendingPathComponent:@"index.html"]:savePath;
		[[NSWorkspace sharedWorkspace] openFile:openPath];				
	}
	
	if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DonateAlertShown"])
	{
		[[AppController sharedController] showDonateAlert];
	}
	
	[self cleanUpAfterDownload];

	[autoreleasePool release];
}

#pragma mark -
#pragma mark Saving

- (void)runSaveSheetWithFilename:(NSString *)filename
{
	// Run a save sheet.
	savePanel = [NSSavePanel savePanel];
	[savePanel setCanSelectHiddenExtension:YES];
	[savePanel setExtensionHidden:NO];
	[savePanel setAccessoryView:formatChooserView];
	[self saveFormatChanged:nil];

	[savePanel beginSheetForDirectory:nil
								 file:filename
					   modalForWindow:[locationBar window]
						modalDelegate:self
					   didEndSelector:@selector(modalSavePanelDidEnd:returnCode:contextInfo:)
						  contextInfo:nil];
}

- (void)modalSavePanelDidEnd:(NSSavePanel *)aSavePanel
				  returnCode:(int)returnCode
				 contextInfo:(NSDictionary *)contextInfo
{
	if (returnCode == NSOKButton)
	{
		savePath = [[aSavePanel filename] retain];
		[NSThread detachNewThreadSelector:@selector(download)
								 toTarget:self
							   withObject:nil];
	}
	else
	{
		// They clicked cancel.
		[self cleanUpAfterDownload];
	}
}

- (IBAction)saveFormatChanged:(id)sender
{
	if (savePanel)
	{
		saveAsFolder = [formatChooserButton indexOfSelectedItem];
		[savePanel setRequiredFileType:(saveAsFolder)?@"":@"pdf"];
		NSString *fileName = [savePanel filename], *extension = [fileName pathExtension];
		if (saveAsFolder && [extension isEqualToString:@"pdf"])
		{
			[savePanel setFilename:[fileName stringByDeletingPathExtension]];
		}
	}
}

#pragma mark -
#pragma mark Life Cycle

- (void)dealloc
{
	[super dealloc];
}

@end
