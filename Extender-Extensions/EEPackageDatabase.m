//
//  EEPackageDatabase.m
//  Extender Installer
//
//  Created by Matt Clarke on 20/04/2017.
//
//

#import "EEPackageDatabase.h"
#import "EEPackage.h"
#import "EEResources.h"
#import "SSZipArchive.h"
#import <objc/runtime.h>
#include <unistd.h>

@interface Extender : UIApplication
- (void)sendLocalNotification:(NSString*)title andBody:(NSString*)body;
-(void)sendLocalNotification:(NSString*)title body:(NSString*)body withID:(NSString*)identifier;
- (_Bool)application:(id)arg1 openURL:(id)arg2 sourceApplication:(id)arg3 annotation:(id)arg4;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *teamID;
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSURL *bundleURL;
+ (instancetype)applicationProxyForIdentifier:(NSString*)arg1;
@end

@interface LSApplicationWorkspace : NSObject
+(instancetype)defaultWorkspace;
-(BOOL)installApplication:(NSURL*)arg1 withOptions:(NSDictionary*)arg2 error:(NSError**)arg3;
- (NSArray*)allApplications;
@end

@interface CydiaObject : NSObject
- (id)isReachable:(id)arg1;
@end

static EEPackageDatabase *sharedDatabase;

@implementation EEPackageDatabase

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    
    dispatch_once(&once, ^{
        sharedDatabase = [[self alloc] init];
    });
    
    return sharedDatabase;
}

- (instancetype)init {
    self = [super init];
    
    if (self) {
        _queue = dispatch_queue_create("com.cydia.Extender.resignQueue", NULL);
    }
    
    return self;
}

- (NSArray *)retrieveAllTeamIDApplications {
    NSString *teamID = [EEResources getTeamID];
    
    if (!teamID || [teamID isEqualToString:@""]) {
        return [NSArray array];
    }
    
    NSMutableArray *identifiers = [NSMutableArray array];
    
    for (LSApplicationProxy *proxy in [[LSApplicationWorkspace defaultWorkspace] allApplications]) {
        if ([[proxy teamID] isEqualToString:teamID]) {
            [identifiers addObject:[proxy applicationIdentifier]];
        }
    }
    
    [identifiers removeObject:@"com.cydia.Extender"];
    
    _teamIDApplications = identifiers;
    
    return _teamIDApplications;
}

- (void)rebuildDatabase {
    /*
     * The database is not exactly it's namesake. It comprises of all the IPAs stored in
     * Documents/Extender/Unsigned.
     *
     * We create a local IPA for each locally provisioned application, so the user doesn't
     * need to manually add an IPA.
     */
    
    [self retrieveAllTeamIDApplications];
    
    // Check if the queue is still being walked.
    if (_installQueue.count != 0) {
        return;
    }
    
    // Clear current IPAs.
    NSString *inbox = [NSString stringWithFormat:@"%@/Unsigned", EXTENDER_DOCUMENTS];
    [[NSFileManager defaultManager] removeItemAtPath:inbox error:nil];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:inbox withIntermediateDirectories:YES attributes:nil error:nil];
    
    // Now, we cache the EEPackage for each IPA created.
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    
    for (NSString *bundleID in  _teamIDApplications) {
        EEPackage *package = [[EEPackage alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/%@.ipa", inbox, bundleID]] andBundleIdentifier:bundleID];
        
        [dict setObject:package forKey:[package bundleIdentifier]];
    }
    
    _packages = [dict copy];
    
    Extender *application = (Extender*)[UIApplication sharedApplication];
    [application sendLocalNotification:@"Debug" andBody:[NSString stringWithFormat:@"Rebuilt database, with %lu entries", (unsigned long)_packages.count]];
}

- (NSURL*)_buildIPAForExistingBundleIdentifier:(NSString*)bundleIdentifier {
    NSString *basePath = [NSString stringWithFormat:@"%@/Unsigned/%@/Payload", EXTENDER_DOCUMENTS, bundleIdentifier];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:basePath withIntermediateDirectories:YES attributes:nil error:nil];
    
    LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleIdentifier];
    NSString *dotAppName = [[proxy.bundleURL path] lastPathComponent];
    
    NSString *fromPath = [proxy.bundleURL path];
    NSString *toPath = [NSString stringWithFormat:@"%@/Unsigned/%@/Payload/%@", EXTENDER_DOCUMENTS, bundleIdentifier, dotAppName];
    
    NSError *error;
    [[NSFileManager defaultManager] copyItemAtPath:fromPath toPath:toPath error:&error];
    
    if (error) {
        Extender *application = (Extender*)[UIApplication sharedApplication];
        [application sendLocalNotification:@"Debug" andBody:[NSString stringWithFormat:@"Could not copy .app (%@) from '%@' due to: %@", toPath, fromPath, error]];
    }
    
    // Compress into an ipa.
    [SSZipArchive createZipFileAtPath:[NSString stringWithFormat:@"%@/Unsigned/%@.ipa", EXTENDER_DOCUMENTS, bundleIdentifier] withContentsOfDirectory:[NSString stringWithFormat:@"%@/Unsigned/%@", EXTENDER_DOCUMENTS, bundleIdentifier]];
    
    // Cleanup.
    [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@/Unsigned/%@", EXTENDER_DOCUMENTS, bundleIdentifier] error:nil];
    
    return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/Unsigned/%@.ipa", EXTENDER_DOCUMENTS, bundleIdentifier]];
}

- (EEPackage*)packageForIdentifier:(NSString*)bundleIdentifier {
    return [_packages objectForKey:bundleIdentifier];
}

- (NSArray*)allPackages {
    return [_packages allValues];
}

- (void)resignApplicationsIfNecessaryWithTaskID:(UIBackgroundTaskIdentifier)bgTask andCheckExpiry:(BOOL)check {
    _currentBgTask = bgTask;
    
    // Check if the queue is still being walked.
    if (_installQueue.count != 0) {
        return;
    }
    
    // If Low Power Mode is enabled, we will not attempt a resign to avoid power consumption.
    if ([[NSProcessInfo processInfo] isLowPowerModeEnabled]) {
        Extender *application = (Extender*)[UIApplication sharedApplication];
        [application sendLocalNotification:@"Debug" andBody:@"Not proceeding to re-sign due to Low Power Mode being active."];
        
        return;
    }
    
    // We should also check network state before proceeding.
    CydiaObject *object = [[objc_getClass("CydiaObject") alloc] init];
    if (![[object isReachable:@"www.google.com"] boolValue]) {
        Extender *application = (Extender*)[UIApplication sharedApplication];
        [application sendLocalNotification:@"Debug" andBody:@"Not proceeding to re-sign due to no network access."];
        
        return;
    }
    
    if (![EEResources username]) {
        Extender *application = (Extender*)[UIApplication sharedApplication];
        [application sendLocalNotification:@"Sign In" body:@"Please login with your Apple ID to re-sign applications." withID:@"login"];
        
        return;
    }
    
    Extender *application = (Extender*)[UIApplication sharedApplication];
    [application sendLocalNotification:@"Debug" andBody:@"Checking if any applications need re-signing."];
    
    NSDate *now = [NSDate date];
    unsigned int unitFlags = NSCalendarUnitDay;
    NSCalendar *currCalendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    
    // Create installQueue if needed.
    if (!_installQueue) {
        _installQueue = [NSMutableArray array];
    } else {
        [_installQueue removeAllObjects];
    }
    
    if (check) {
        for (EEPackage *package in [self allPackages]) {
        
            NSDateComponents *conversionInfo = [currCalendar components:unitFlags fromDate:now toDate:[package applicationExpireDate] options:0];
            int days = (int)[conversionInfo day];
        
            if (days < [EEResources thresholdForResigning]) {
                [_installQueue addObject:[package bundleIdentifier]];
            }
        }
    } else {
        for (EEPackage *package in [self allPackages]) {
            [_installQueue addObject:[package bundleIdentifier]];
        }
    }
    
    if (_installQueue.count == 0) {
        Extender *application = (Extender*)[UIApplication sharedApplication];
        [application sendLocalNotification:nil andBody:@"No applications need re-signing at this time."];
    }
    
    // Note that this WILL modify the queue, so any checks for count should be done before.
    [self _initiateNextInstallFromQueue];
}

- (void)_initiateNextInstallFromQueue {
    if ([_installQueue count] == 0) {
        // We can exit now.
        [[UIApplication sharedApplication] endBackgroundTask:_currentBgTask];
        _currentBgTask = UIBackgroundTaskInvalid;
    } else {
        // Pull next off the front of the array.
        NSString *identifier = [[_installQueue firstObject] copy];
        [_installQueue removeObjectAtIndex:0];
        
        EEPackage *package = [self packageForIdentifier:identifier];
        [self resignPackage:package];
    }
}

- (void)resignPackage:(EEPackage*)package {
    // Note that we come into here on the global queue for async. We need a new queue on which to place
    // a resign request, else it'll block.
    
    // Build the IPA for this application now.
    [self _buildIPAForExistingBundleIdentifier:[package bundleIdentifier]];
    
    Extender *application = (Extender*)[UIApplication sharedApplication];
    [application sendLocalNotification:@"Debug" andBody:[NSString stringWithFormat:@"Requesting re-sign for: '%@'", [package applicationName]]];
    
    dispatch_async(_queue, ^{
        [application application:application openURL:[package packageURL] sourceApplication:application annotation:nil];
    });
}

- (void)errorDidOccur:(NSString*)message {
    // When any error occurs, clear the installation queue so we can try again later.
    [_installQueue removeAllObjects];
    
    // The meat of the error message is 2x \n in.
    NSArray *split = [message componentsSeparatedByString:@"\n"];
    
    NSString *errorMessage = [NSString stringWithFormat:@"%@\n(%@)", [split lastObject], [split objectAtIndex:1]];
    
    // Now, display to the user we had an error.
    Extender *application = (Extender*)[UIApplication sharedApplication];
    [application sendLocalNotification:@"Error" body:errorMessage withID:@"lastError"];
}

- (void)installPackageAtURL:(NSURL*)url withManifest:(NSDictionary*)manifest {
    Extender *application = (Extender*)[UIApplication sharedApplication];
    
    // There is a possibility we may be called twice here!
    if (![[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
        return;
    }
    
    // Move this package to Documents/Extender/Signed/<uniquename>.ipa
    
    [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithFormat:@"%@/Signed/", EXTENDER_DOCUMENTS]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    NSError *error1;
    NSString *pkgName = [NSString stringWithFormat:@"pkg_%f", [[NSDate date] timeIntervalSince1970]];
    NSString *toPath = [NSString stringWithFormat:@"%@/Signed/%@.ipa", EXTENDER_DOCUMENTS, pkgName];
    
    if (![[NSFileManager defaultManager] moveItemAtPath:[url path] toPath:toPath error:&error1]) {
        NSLog(@"ERROR: %@", error1);
        
        [application sendLocalNotification:@"Debug" andBody:[NSString stringWithFormat:@"Failed to move to path: '%@', with error: %@", toPath, error1.description]];
        
        return;
    }
    
    url = [NSURL fileURLWithPath:toPath];
    
    // The manifest will contain the bundleIdentifier and the display name.
    NSDictionary *item = [[manifest objectForKey:@"items"] firstObject];
    NSDictionary *metadata = [item objectForKey:@"metadata"];
    
    NSString *bundleID = [metadata objectForKey:@"bundle-identifier"];
    NSString *title = [metadata objectForKey:@"title"];
    
    // We can now begin installation, and allow us to move onto the next application.
    dispatch_async(_queue, ^{
        NSError *error;
        NSDictionary *options = @{@"CFBundleIdentifier" : bundleID, @"AllowInstallLocalProvisioned" : [NSNumber numberWithBool:YES]};
    
        BOOL result = [[LSApplicationWorkspace defaultWorkspace] installApplication:url
                                                      withOptions:options
                                                            error:&error];
    
        if (!result) {
            [application sendLocalNotification:@"Failed" body:[NSString stringWithFormat:@"Failed to re-sign: '%@' with error: %@", title, error.localizedDescription] withID:@"lastError"];
        } else {
            // Note that we should change the alert's text based upon if the user has installed this application before.
            
            LSApplicationProxy *proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleID];
            
            [application sendLocalNotification:@"Success" andBody:[NSString stringWithFormat:@"%@: '%@'", proxy != nil ? @"Re-signed" : @"Installed", title]];
        }
    
        // Clean up.
        [[NSFileManager defaultManager] removeItemAtPath:toPath error:nil];
    });
    
    // Signal that we can continue to the next application, as we've signed this one and queued it for installation.
    [self _initiateNextInstallFromQueue];
}

@end
