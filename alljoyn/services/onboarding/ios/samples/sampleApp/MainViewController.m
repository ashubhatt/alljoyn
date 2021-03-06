/******************************************************************************
 * Copyright AllSeen Alliance. All rights reserved.
 *
 *    Permission to use, copy, modify, and/or distribute this software for any
 *    purpose with or without fee is hereby granted, provided that the above
 *    copyright notice and this permission notice appear in all copies.
 *
 *    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 *    WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 *    MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 *    ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 *    WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 *    ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 *    OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 ******************************************************************************/

#import "MainViewController.h"
#import "SystemConfiguration/CaptiveNetwork.h"
#import "AJNStatus.h"
#import "AJNPasswordManager.h"
#import "alljoyn/about/AJNAnnouncement.h"
#import "alljoyn/about/AJNAnnouncementReceiver.h"
#import "alljoyn/about/AJNAboutDataConverter.h"
#import "ClientInformation.h"
#import "AnnounceTextViewController.h"
#import "GetAboutCallViewController.h"
#import "OnboardingViewController.h"
#import "AuthenticationListenerImpl.h"
#include <qcc/Log.h>


static bool ALLOWREMOTEMESSAGES = true; // About Client -  allow Remote Messages flag
static NSString * const APPNAME = @"AboutClientMain"; // About Client - default application name
static NSString * const DAEMON_QUIET_PREFIX  = @"quiet@";   // About Client - quiet advertising
static NSString * const ONBOARDING_OBJECT_PATH = @"/Onboarding";
static NSString * const ONBOARDING_INTERFACE_NAME = @"org.alljoyn.Onboarding";
static NSString * const DEFAULT_REALM_BUS_NAME = @"org.alljoyn.BusNode.onboardingClient";

static NSString * const SSID_NOT_CONNECTED = @"SSID:not connected";

@interface MainViewController ()
@property NSString *className;

// About Client properties
@property (strong, nonatomic) AJNBusAttachment *clientBusAttachment;
@property (strong, nonatomic) AJNAnnouncementReceiver *announcementReceiver;
@property (strong, nonatomic) NSString *realmBusName;
@property (nonatomic) bool isAboutClientConnected;
@property (strong, nonatomic) NSMutableDictionary *clientInformationDict; // Store the client related information

// Announcement
@property (strong, nonatomic) NSString *announcementButtonCurrentTitle;                  // The pressed button's announcementUniqueName
@property (strong, nonatomic) dispatch_queue_t annBtnCreationQueue;

// About Client strings
@property (strong, nonatomic) NSString *ajconnect;
@property (strong, nonatomic) NSString *ajdisconnect;
@property (strong, nonatomic) NSString *annSubvTitleLabelDefaultTxt;

// About Client alerts
@property (strong, nonatomic) UIAlertView *disconnectAlert;
@property (strong, nonatomic) UIAlertView *announcementOptionsAlert;
@property (strong, nonatomic) UIAlertView *onboardingOptionsAlert;

@property (strong, nonatomic) AuthenticationListenerImpl *authenticationListenerImpl;

@end

@implementation MainViewController

#pragma mark - Built In methods
- (void)viewDidLoad
{
	[super viewDidLoad];
    
    [self loadNewSession];

    [self updateSSIDinTitle];
    
    [NSTimer scheduledTimerWithTimeInterval:5.0
                                     target:self
                                   selector:@selector(updateSSIDinTitle)
                                   userInfo:nil
                                    repeats:YES];
    
}

-(void)updateSSIDinTitle
{
    static BOOL executing;
    
    if(executing)
        return;
    
    executing = YES;
    // this code does not work in the simulator
    NSArray *supportedInterfaces = (__bridge_transfer id)CNCopySupportedInterfaces();
//    NSLog(@"supportedInterfaces: %@", supportedInterfaces);
    id interfaceInformation = nil;
    for (NSString *interfaceName in supportedInterfaces) {
        interfaceInformation = (__bridge_transfer id)CNCopyCurrentNetworkInfo((__bridge CFStringRef)interfaceName);
//        NSLog(@"    %@:%@", interfaceName, interfaceInformation);
        NSDictionary *dict = interfaceInformation;
        NSString *title = [NSString stringWithFormat:@"Devices on: %@",dict[@"SSID"]];
        
        // Set the instructions Label text according to the network type
        if ([dict[@"SSID"] hasPrefix:AJ_AP_PREFIX] || [dict[@"SSID"] hasSuffix:AJ_AP_SUFFIX]) {
            self.instructionsLabel.text = @"You are currently connected to a device Access Point.\n\nPress \"Connect to AllJoyn\" to see the device in the list above.\n\nPress on the device name->onboarding to start onboarding.";
        } else {
            self.instructionsLabel.text =  @"To onboard a new device:\nConnect to the device's Wi-Fi Access Point by going to Settings -> Wi-Fi\n\nTo see the devices on this network:\nPress \"Connect to AllJoyn\"";
        }
        
        if (![self.title isEqualToString:title]) {
            if ((![dict[@"SSID"] hasPrefix:AJ_AP_PREFIX] && ![dict[@"SSID"] hasSuffix:AJ_AP_SUFFIX]) && ![dict[@"SSID"] isEqualToString:[[NSUserDefaults standardUserDefaults]valueForKey:@"lastVisitedNetwork"]]) {
                NSLog(@"setting lastVisitedNetwork to: %@", dict[@"SSID"]);
                [[NSUserDefaults standardUserDefaults] setValue:dict[@"SSID"] forKey:@"lastVisitedNetwork"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }

            self.title = title;
            if (self.isAboutClientConnected) {
                NSLog(@"changing network to %@ trigger a restart", dict[@"SSID"]);
                [[[UIAlertView alloc]initWithTitle:@"Wi-Fi network changed" message:@"Please reconnect to AllJoyn" delegate:Nil cancelButtonTitle:@"OK" otherButtonTitles: nil] show];
                [self.navigationController popViewControllerAnimated:YES];
                [self stopAboutClient];
            }
        }
        
        if (interfaceInformation && [interfaceInformation count]) { break; }
    }
    
    if ([self.title isEqualToString:@""]) {
        self.title = SSID_NOT_CONNECTED;
    }
    
    executing = NO;
}

// Get the user's input from the alert dialog
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView == self.announcementOptionsAlert) {
		[self performAnnouncementAction:buttonIndex];
	}
	else if (alertView == self.onboardingOptionsAlert) {
		[self performAnnouncementAction:buttonIndex];
	}
    else {
		NSLog(@"[%@] [%@] alertView.tag is wrong", @"ERROR", [[self class] description]);
	}
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue
                 sender:(id)sender
{
    // GetAboutCallViewController
	if ([segue.destinationViewController isKindOfClass:[GetAboutCallViewController class]]) {
		GetAboutCallViewController *getAboutCallView = segue.destinationViewController;
		getAboutCallView.clientInformation = (self.clientInformationDict)[self.announcementButtonCurrentTitle];
		getAboutCallView.clientBusAttachment = self.clientBusAttachment;
	}
    // AnnounceTextViewController
	else if ([segue.destinationViewController isKindOfClass:[AnnounceTextViewController class]]) {
		AnnounceTextViewController *announceTextViewController = segue.destinationViewController;
		announceTextViewController.ajnAnnouncement = [(ClientInformation *)(self.clientInformationDict)[self.announcementButtonCurrentTitle] announcement];
	}
    else if ([segue.destinationViewController isKindOfClass:[OnboardingViewController class]])
    {
        OnboardingViewController *onboardingViewController = segue.destinationViewController;
        onboardingViewController.clientBusName = self.clientBusAttachment;
        onboardingViewController.clientInformation = (self.clientInformationDict)[self.announcementButtonCurrentTitle];
    }
}

#pragma mark - IBAction Methods
- (IBAction)connectButtonDidTouchUpInside:(id)sender
{
	// Connect to the bus with the default realm bus name
	if (!self.isAboutClientConnected) {
		[self startAboutClient];
	} else {
        [self stopAboutClient];
	}
}

#pragma mark - AJNAnnouncementListener protocol method
// Here we receive an announcement from AJN and add it to the client's list of services avaialble
- (void)announceWithVersion:(uint16_t)version
                       port:(uint16_t)port
                    busName:(NSString *)busName
         objectDescriptions:(NSMutableDictionary *)objectDescs
                  aboutData:(NSMutableDictionary **)aboutData
{
	NSString *announcementUniqueName; // Announcement unique name in a format of <busName DeviceName>
	ClientInformation *clientInformation = [[ClientInformation alloc] init];
    
	// Save the announcement in a AJNAnnouncement
	clientInformation.announcement = [[AJNAnnouncement alloc] initWithVersion:version port:port busName:busName objectDescriptions:objectDescs aboutData:aboutData];
    
	// Generate an announcement unique name in a format of <busName DeviceName>
	announcementUniqueName = [NSString stringWithFormat:@"%@ %@", [clientInformation.announcement busName], [AJNAboutDataConverter messageArgumentToString:[clientInformation.announcement aboutData][@"DeviceName"]]];
    
    NSLog(@"[%@] [%@] Announcement unique name [%@]", @"DEBUG", [[self class] description], announcementUniqueName);
    
	AJNMessageArgument *annObjMsgArg = [clientInformation.announcement aboutData][@"AppId"];
	uint8_t *appIdBuffer;
	size_t appIdNumElements;
	QStatus status;
	status = [annObjMsgArg value:@"ay", &appIdNumElements, &appIdBuffer];
    
	// Add the received announcement
	if (status != ER_OK) {
        NSLog(@"[%@] [%@] Failed to read appId for key [%@]", @"DEBUG", [[self class] description], announcementUniqueName);

		return;
	}
    
	// Dealing with announcement entries should be syncronized, so we add it to a queue
	dispatch_sync(self.annBtnCreationQueue, ^{
	    bool isAppIdExists = false;
	    uint8_t *tmpAppIdBuffer;
	    size_t tmpAppIdNumElements;
	    QStatus tStatus;
	    int res;
        
	    // Iterate over the announcements dictionary
	    for (NSString *key in self.clientInformationDict.allKeys) {
	        ClientInformation *clientInfo = [self.clientInformationDict valueForKey:key];
	        AJNAnnouncement *announcement = [clientInfo announcement];
	        AJNMessageArgument *tmpMsgrg = [announcement aboutData][@"AppId"];
            
	        tStatus = [tmpMsgrg value:@"ay", &tmpAppIdNumElements, &tmpAppIdBuffer];
	        if (tStatus != ER_OK) {
                NSLog(@"[%@] [%@] Failed to read appId for key [%@]", @"DEBUG", [[self class] description], key);

	            return;
			}
            
	        res = 1;
	        if (appIdNumElements == tmpAppIdNumElements) {
	            res = memcmp(appIdBuffer, tmpAppIdBuffer, appIdNumElements);
			}
            
	        // Found a matched appId - res=0
	        if (!res) {
	            isAppIdExists = true;
	            // Same AppId and the same announcementUniqueName
	            if ([key isEqualToString:announcementUniqueName]) {
	                // Update only announcements dictionary
                    
                     NSLog(@"[%@] [%@] Got an announcement from a known device - updating the announcement object", @"DEBUG", [[self class] description]);

                    (self.clientInformationDict)[announcementUniqueName] = clientInformation;
	                // Same AppId but *different* announcementUniqueName
				}
	            else {
                     NSLog(@"[%@] [%@] Got an announcement from a known device(different bus name) - updating the announcement object and UI ", @"DEBUG", [[self class] description]);
                    
	                // Cancel advertise name if the bus name has changed
	                NSString *prevBusName = [announcement busName];
	                if (!([busName isEqualToString:prevBusName])) {
	                    tStatus = [self.clientBusAttachment cancelFindAdvertisedName:prevBusName];
	                    if (status != ER_OK) {
                            NSLog(@"[%@] [%@] failed to cancelAdvertisedName for %@. status:%@", @"DEBUG", [[self class] description],prevBusName, [AJNStatus descriptionForStatusCode:tStatus]);
                        }
					}
	                // Remove existed record from the announcements dictionary
	                [self.clientInformationDict removeObjectForKey:key];
	                // Add new record to the announcements dictionary
	                [self.clientInformationDict setValue:clientInformation forKey:announcementUniqueName];
                    [self.servicesTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
				}
	            break;
			} //if
		} //for
        
	    //appId doesn't exist and  there is no match announcementUniqueName
	    if (!(self.clientInformationDict)[announcementUniqueName] && !isAppIdExists) {
	        // Add new pair with this AboutService information (version,port,bus name, object description and about data)
	        [self.clientInformationDict setValue:clientInformation forKey:announcementUniqueName];
	        [self addNewAnnouncemetEntry];
            
	        // AppId doesn't exist and BUT there is no match announcementUniqueName
		} // else No OP
    });
    
	// Register interest in a well-known name prefix for the purpose of discovery (didLoseAdertise)
	[self.clientBusAttachment enableConcurrentCallbacks];
	status = [self.clientBusAttachment findAdvertisedName:busName];
	if (status != ER_OK) {
         NSLog(@"[%@] [%@] failed to findAdvertisedName for %@. status:%@", @"ERROR", [[self class] description],busName, [AJNStatus descriptionForStatusCode:status]);
	}
}

#pragma mark AJNBusListener protocol methods

- (void)didFindAdvertisedName:(NSString *)name
            withTransportMask:(AJNTransportMask)transport
                   namePrefix:(NSString *)namePrefix
{
	NSLog(@"didFindAdvertisedName %@", name);
}

- (void)didLoseAdvertisedName:(NSString *)name
            withTransportMask:(AJNTransportMask)transport
                   namePrefix:(NSString *)namePrefix
{
	NSLog(@"didLoseAdvertisedName");
	QStatus status;
	// Find the button title that should be removed
	for (NSString *key in[self.clientInformationDict allKeys]) {
		if ([[[[self.clientInformationDict valueForKey:key] announcement] busName] isEqualToString:name]) {
			// Cancel advertise name for that bus
			status = [self.clientBusAttachment cancelFindAdvertisedName:name];
			if (status != ER_OK) {
                 NSLog(@"[%@] [%@] failed to cancelFindAdvertisedName for %@. status:%@", @"DEBUG", [[self class] description],name, [AJNStatus descriptionForStatusCode:status]);
            }
			// Remove the anouncement from the dictionary
			[self.clientInformationDict removeObjectForKey:key];
		}
	}
    
	[self.servicesTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
}

#pragma mark - util methods
- (void)loadNewSession
{
    // About flags
	self.isAboutClientConnected  = false;
    
	self.annBtnCreationQueue = dispatch_queue_create("org.alljoyn.announcementbuttoncreationQueue", NULL);
    
	// Set About Client strings
	self.ajconnect = @"Connect to AllJoyn";
	self.ajdisconnect = @"Disconnect from AllJoyn";
	self.realmBusName = DEFAULT_REALM_BUS_NAME;
	self.annSubvTitleLabelDefaultTxt = @"Announcement of ";
	// Set About Client connect button
//	self.connectButton.backgroundColor = [UIColor darkGrayColor]; //button bg color
//	[self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; //button font color
	[self.connectButton setTitle:self.ajconnect forState:UIControlStateNormal]; //default text
    
	[self prepareAlerts];
}

//  Initialize alerts
- (void)prepareAlerts
{
	// announcementOptionsAlert.tag = 3
	self.announcementOptionsAlert = [[UIAlertView alloc] initWithTitle:@"Choose option:" message:@"" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Show Announce", @"About", nil];
	self.announcementOptionsAlert.alertViewStyle = UIAlertViewStyleDefault;
    
	// onboardingOptionsAlert.tag = 4
	self.onboardingOptionsAlert = [[UIAlertView alloc] initWithTitle:@"Choose option:" message:@"" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Show Announce", @"About", @"Onboarding", nil];
	self.onboardingOptionsAlert.alertViewStyle = UIAlertViewStyleDefault;
    
}

- (void)performAnnouncementAction:(NSInteger)opt
{
	switch (opt) {
		case 0: // "Cancel"
			break;
            
		case 1: // "Show Announce"
		{
			[self performSegueWithIdentifier:@"AboutShowAnnounceSegue" sender:self];
		}
            break;
            
		case 2: // "About"
		{
			[self performSegueWithIdentifier:@"AboutClientSegue" sender:self]; // get the announcment object
            
		}
            break;
            
		case 3: // "OnBoarding"
		{
            [self performSegueWithIdentifier:@"OnboardingClientSegue" sender:self]; // get the announcment object
        }
            break;
            
		default:
			break;
	}
}

- (void)AlertAndLog:(NSString *)level message:(NSString *)message status:(QStatus)status
{
    NSString *alertText = [NSString stringWithFormat:@"%@ (%@)",message, [AJNStatus descriptionForStatusCode:status]];
    NSLog(@"[%@] [%@] %@", level, [[self class] description], alertText);
    
    [[[UIAlertView alloc] initWithTitle:@"Startup Error" message:alertText delegate:nil cancelButtonTitle:@"OK" otherButtonTitles: nil] show];
}


#pragma mark - AboutClient
#pragma mark start AboutClient

- (void)startAboutClient
{
	QStatus status;
    
    // Create a dictionary to contain announcements using a key in the format of: "announcementUniqueName + announcementObj"
	self.clientInformationDict = [[NSMutableDictionary alloc] init];
    
     NSLog(@"[%@] [%@] Start About Client", @"DEBUG", [[self class] description]);

    
	// Init AJNBusAttachment
	self.clientBusAttachment = [[AJNBusAttachment alloc] initWithApplicationName:APPNAME allowRemoteMessages:ALLOWREMOTEMESSAGES];
    
	// Start AJNBusAttachment
	status = [self.clientBusAttachment start];
	if (status != ER_OK) {
        [self AlertAndLog:@"FATAL" message:@"Failed AJNBusAttachment start" status:status];
        [self stopAboutClient];
        return;
	}
    
	// Connect AJNBusAttachment
	status = [self.clientBusAttachment connectWithArguments:@""];
	if (status != ER_OK) {
        [self AlertAndLog:@"FATAL" message:@"Failed AJNBusAttachment connectWithArguments" status:status];
        [self stopAboutClient];

        return;
	}
    
    NSLog(@"[%@] [%@] Create aboutClientListener", @"DEBUG", [[self class] description]);
    NSLog(@"[%@] [%@] Register aboutClientListener", @"DEBUG", [[self class] description]);

	[self.clientBusAttachment registerBusListener:self];
    
	self.announcementReceiver = [[AJNAnnouncementReceiver alloc] initWithAnnouncementListener:self andBus:self.clientBusAttachment];
    const char* interfaces[] = { [ONBOARDING_INTERFACE_NAME UTF8String] };
	status = [self.announcementReceiver registerAnnouncementReceiverForInterfaces:interfaces withNumberOfInterfaces:1];
	if (status != ER_OK) {
        [self AlertAndLog:@"FATAL" message:@"Failed to registerAnnouncementReceiver" status:status];
        [self stopAboutClient];

        return;
	}
    

    
    NSUUID *UUID = [NSUUID UUID];
    NSString *stringUUID = [UUID UUIDString];
    
    self.realmBusName = [NSString stringWithFormat:@"%@-%@", DEFAULT_REALM_BUS_NAME, stringUUID];
    
	// Advertise Daemon for tcl
	status = [self.clientBusAttachment requestWellKnownName:self.realmBusName withFlags:kAJNBusNameFlagDoNotQueue];
	if (status == ER_OK) {
		// Advertise the name with a quite prefix for TC to find it
		status = [self.clientBusAttachment advertiseName:[NSString stringWithFormat:@"%@%@", DAEMON_QUIET_PREFIX, self.realmBusName] withTransportMask:kAJNTransportMaskAny];
		if (status != ER_OK) {
            
            [self AlertAndLog:@"FATAL" message:@"Failed to advertise name" status:status];
            
            NSLog(@"[%@] [%@] Failed advertising: %@%@", @"ERROR", [[self class] description], DAEMON_QUIET_PREFIX, self.realmBusName);
            
            [self stopAboutClient];
            
            return;
		}
		else {
            NSLog(@"[%@] [%@] Successfully advertised: %@%@", @"DEBUG", [[self class] description], DAEMON_QUIET_PREFIX, self.realmBusName);
		}
	}
	else {
        [self AlertAndLog:@"FATAL" message:@"Failed to requestWellKnownName" status:status];
        [self stopAboutClient];
        
        return;

	}
    
    // Enable Client Security
    self.authenticationListenerImpl = [[AuthenticationListenerImpl alloc] init];
    status = [self enableClientSecurity];
    if (ER_OK != status) {
        [self AlertAndLog:@"ERROR" message:@"Failed to enable security. Please uninstall the application and reinstall." status:status];
    } else {
        NSLog(@"Successfully enabled security for the bus");
    }

	[self.connectButton setTitle:self.ajdisconnect forState:UIControlStateNormal]; //change title to "Disconnect from AllJoyn"
	self.isAboutClientConnected = true;
}


- (QStatus)enableClientSecurity
{
    QStatus status;
    status = [self.clientBusAttachment enablePeerSecurity:@"ALLJOYN_SRP_KEYX ALLJOYN_PIN_KEYX ALLJOYN_ECDHE_PSK" authenticationListener:self.authenticationListenerImpl keystoreFileName:@"Documents/alljoyn_keystore/s_central.ks" sharing:YES];
    
    if (status != ER_OK) { //try to delete the keystore and recreate it, if that fails return failure
        NSError *error;
        NSString *keystoreFilePath = [NSString stringWithFormat:@"%@/alljoyn_keystore/s_central.ks", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0]];
        [[NSFileManager defaultManager] removeItemAtPath:keystoreFilePath error:&error];
        if (error) {
            NSLog(@"ERROR: Unable to delete keystore. %@", error);
            return ER_AUTH_FAIL;
        }
        
        status = [self.clientBusAttachment enablePeerSecurity:@"ALLJOYN_SRP_KEYX ALLJOYN_PIN_KEYX ALLJOYN_ECDHE_PSK" authenticationListener:self.authenticationListenerImpl keystoreFileName:@"Documents/alljoyn_keystore/s_central.ks" sharing:YES];
    }
    return status;
}

- (void)addNewAnnouncemetEntry
{
	[self.servicesTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
}

// announcementGetMoreInfo is an IBAction triggered by pressing a dynamic announcement button
- (void)announcementGetMoreInfo:(NSInteger)requestedRow
{
	// set the announcementButtonCurrentTitle
	self.announcementButtonCurrentTitle = [self.clientInformationDict allKeys][requestedRow];
    
     NSLog(@"[%@] [%@] Requested:  [%@]", @"DEBUG", [[self class] description],self.announcementButtonCurrentTitle);
    
    // Check if announcement has icon object path
	if (![self announcementSupportsInterface:self.announcementButtonCurrentTitle]) {
		[self.announcementOptionsAlert show]; // Event is forward to alertView: clickedButtonAtIndex:
	}
	else {
		[self.onboardingOptionsAlert show]; // Event is forward to alertView: clickedButtonAtIndex:
	}
}

// Return true if an announcement supports icon interface
- (bool)announcementSupportsInterface:(NSString *)announcementKey
{
	bool supportInterface = false;
	AJNAnnouncement *announcement = [(ClientInformation *)[self.clientInformationDict valueForKey:announcementKey] announcement];
	NSMutableDictionary *announcementObjDecs = [announcement objectDescriptions]; //Dictionary of ObjectDescriptions NSStrings
    
	// iterate over the object descriptions dictionary
	for (NSString *key in announcementObjDecs.allKeys) {
		if ([key hasPrefix:ONBOARDING_OBJECT_PATH]) {
			// Iterate over the NSMutableArray
			for (NSString *intf in[announcementObjDecs valueForKey:key]) {
				if ([intf isEqualToString:(NSString *)ONBOARDING_INTERFACE_NAME]) {
					supportInterface = true;
				}
			}
		}
	}
	return supportInterface;
}

#pragma mark stop AboutClient
- (void)stopAboutClient
{
	QStatus status;
     NSLog(@"[%@] [%@] Stop About Client", @"DEBUG", [[self class] description]);
    
	// Bus attachment cleanup
	status = [self.clientBusAttachment cancelAdvertisedName:[NSString stringWithFormat:@"%@%@", DAEMON_QUIET_PREFIX, self.realmBusName] withTransportMask:kAJNTransportMaskAny];
	if (status == ER_OK) {
         NSLog(@"[%@] [%@] Successfully cancel advertised name", @"DEBUG", [[self class] description]);
	} else {
        NSLog(@"[%@] [%@]  Failed cancel advertised name, error:%@", @"DEBUG", [[self class] description],[AJNStatus descriptionForStatusCode:status]);

    }
    
	status = [self.clientBusAttachment releaseWellKnownName:self.realmBusName];
	if (status == ER_OK) {
         NSLog(@"[%@] [%@] Successfully release WellKnownName", @"DEBUG", [[self class] description]);
	} else {
        NSLog(@"[%@] [%@]  Failed release WellKnownName, error:%@", @"DEBUG", [[self class] description],[AJNStatus descriptionForStatusCode:status]);
        
    }
    
    
    
	status = [self.clientBusAttachment removeMatchRule:@"sessionless='t',type='error'"];
	if (status == ER_OK) {
         NSLog(@"[%@] [%@] Successfully remove MatchRule", @"DEBUG", [[self class] description]);
	} else {
        NSLog(@"[%@] [%@]  Failed remove MatchRule, error:%@", @"DEBUG", [[self class] description],[AJNStatus descriptionForStatusCode:status]);
        
    }
    
	// Cancel advertise name for each announcement bus
	for (NSString *key in[self.clientInformationDict allKeys]) {
		ClientInformation *clientInfo = (self.clientInformationDict)[key];
		status = [self.clientBusAttachment cancelFindAdvertisedName:[[clientInfo announcement] busName]];
		if (status != ER_OK) {
             NSLog(@"[%@] [%@] failed to cancelAdvertisedName for %@. status:%@", @"ERROR", [[self class] description],key, [AJNStatus descriptionForStatusCode:status]);
		} 
	}
	self.clientInformationDict = nil;
    
    const char* interfaces[] = { [ONBOARDING_INTERFACE_NAME UTF8String] };
	status = [self.announcementReceiver unRegisterAnnouncementReceiverForInterfaces:interfaces withNumberOfInterfaces:1];
	if (status == ER_OK) {
         NSLog(@"[%@] [%@] Successfully unregistered AnnouncementReceiver", @"DEBUG", [[self class] description]);
	} else {
        NSLog(@"[%@] [%@]  Failed unregistered AnnouncementReceiver, error:%@", @"DEBUG", [[self class] description],[AJNStatus descriptionForStatusCode:status]);
        
    }
    
	self.announcementReceiver = nil;
    
	// Stop bus attachment
	status = [self.clientBusAttachment stop];
	if (status == ER_OK) {
         NSLog(@"[%@] [%@] Successfully stopped bus", @"DEBUG", [[self class] description]);
    } else {
        NSLog(@"[%@] [%@]  Failed stopping bus, error:%@", @"DEBUG", [[self class] description],[AJNStatus descriptionForStatusCode:status]);
        
    }
    
	self.clientBusAttachment = nil;
    
	// Set flag
	self.isAboutClientConnected  = false;
    
	// UI cleanup
	[self.connectButton setTitle:self.ajconnect forState:UIControlStateNormal];
    
	[self.servicesTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
    
     NSLog(@"[%@] [%@] About Client is stopped", @"DEBUG", [[self class] description]);
}

#pragma mark UITableView delegates
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return [self.clientInformationDict count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	static NSString *MyIdentifier = @"AnnouncementCell";
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:MyIdentifier forIndexPath:indexPath];
    
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
    
	cell.textLabel.text = [self.clientInformationDict allKeys][indexPath.row];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[self announcementGetMoreInfo:indexPath.row];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath
{
    [self announcementGetMoreInfo:indexPath.row];
}

@end
