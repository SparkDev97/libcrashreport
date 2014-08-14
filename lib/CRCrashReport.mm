/**
 * Name: libcrashreport
 * Type: iOS/OS X shared library
 * Desc: Library for parsing and symbolicating iOS crash log files.
 *
 * Author: Lance Fetters (aka. ashikase)
 * License: LGPL v3 (See LICENSE file for details)
 */

#import "CRCrashReport.h"

#import <libpackageinfo/libpackageinfo.h>
#import <libsymbolicate/libsymbolicate.h>
#import <RegexKitLite/RegexKitLite.h>
#import "CRBinaryImage.h"
#import "CRException.h"
#import "CRStackFrame.h"
#import "CRThread.h"

#include <notify.h>
#include <time.h>
#include "common.h"
#include "system_info.h"

// NOTE: These are are allowed to be accessed externally.
NSString * const kCrashReportBlame = @"blame";
NSString * const kCrashReportDescription = @"description";
NSString * const kCrashReportSymbolicated = @"symbolicated";

static uint64_t uint64FromHexString(NSString *string) {
    return (uint64_t)unsignedLongLongFromHexString([string UTF8String], [string length]);
}

@interface CRCrashReport ()
@property(nonatomic, retain) NSDictionary *properties;
@property(nonatomic, retain) CRException *exception;
@property(nonatomic, retain) NSArray *threads;
@property(nonatomic, retain) NSArray *registerState;
@property(nonatomic, retain) NSDictionary *binaryImages;
@property(nonatomic, assign) BOOL isPropertyList;

@property(nonatomic, retain) NSArray *processInfoKeys;
@property(nonatomic, retain) NSArray *processInfoObjects;
@end

@implementation CRCrashReport {
    CRCrashReportFilterType filterType_;
    BOOL isAlreadySymbolicated_;
    BOOL processingDeviceIsCrashedDevice_;
}

@synthesize properties = properties_;
@synthesize exception = exception_;
@synthesize threads = threads_;
@synthesize registerState = registerState_;
@synthesize binaryImages = binaryImages_;

@synthesize processInfoKeys = processInfoKeys_;
@synthesize processInfoObjects = processInfoObjects_;

@dynamic isSymbolicated;

#pragma mark - Public API (Creation)

+ (CRCrashReport *)crashReportWithData:(NSData *)data {
    return [[[self alloc] initWithData:data filterType:CRCrashReportFilterTypeFile] autorelease];
}

+ (CRCrashReport *)crashReportWithData:(NSData *)data filterType:(CRCrashReportFilterType)filterType {
    return [[[self alloc] initWithData:data filterType:filterType] autorelease];
}

+ (CRCrashReport *)crashReportWithFile:(NSString *)filepath {
    return [[[self alloc] initWithFile:filepath filterType:CRCrashReportFilterTypeFile] autorelease];
}

+ (CRCrashReport *)crashReportWithFile:(NSString *)filepath filterType:(CRCrashReportFilterType)filterType {
    return [[[self alloc] initWithFile:filepath filterType:filterType] autorelease];
}

- (id)initWithData:(NSData *)data {
    return [self initWithData:data filterType:CRCrashReportFilterTypeFile];
}

- (id)initWithData:(NSData *)data filterType:(CRCrashReportFilterType)filterType {
    self = [super init];
    if (self != nil) {
        // Attempt to load data as a property list.
        id plist = nil;
        if ([NSPropertyListSerialization respondsToSelector:@selector(propertyListWithData:options:format:error:)]) {
            plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
        } else {
            plist = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:0 format:NULL errorDescription:NULL];
        }

        if (plist != nil) {
            // Confirm that input file is a crash log.
            if ([plist isKindOfClass:[NSDictionary class]] && [plist objectForKey:@"SysInfoCrashReporterKey"] != nil) {
                properties_ = [plist retain];
                [self setIsPropertyList:YES];
            } else {
                fprintf(stderr, "ERROR: Input file is not a valid PLIST crash report.\n");
                [self release];
                return nil;
            }
        } else {
            // Assume file is of IPS format.
            Class $NSJSONSerialization = NSClassFromString(@"NSJSONSerialization");
            if ($NSJSONSerialization == nil) {
                fprintf(stderr, "ERROR: This version of iOS does not include NSJSONSerialization, which is required for parsing IPS files.\n");
                [self release];
                return nil;
            }

            NSString *string = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
            NSRange range = [string rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
            if ((range.location != NSNotFound) && ((range.location + 1) < [string length])) {
                NSString *header = [string substringToIndex:range.location];
                NSString *description = [string substringFromIndex:(range.location + 1)];
                NSError *error = nil;
                id object = [$NSJSONSerialization JSONObjectWithData:[header dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
                if (object != nil) {
                    if ([object isKindOfClass:[NSDictionary class]]) {
                        NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithDictionary:object];
                        [dict setObject:description forKey:kCrashReportDescription];
                        properties_ = [dict retain];
                    } else {
                        fprintf(stderr, "ERROR: IPS header is not correct format.\n");
                        [self release];
                        return nil;
                    }
                } else {
                    fprintf(stderr, "ERROR: Unable to parse IPS file header: %s.\n", [[error localizedDescription] UTF8String]);
                    [self release];
                    return nil;
                }
            } else {
                fprintf(stderr, "ERROR: Input file is not a valid IPS crash report.\n");
                [self release];
                return nil;
            }
        }

        // Store filter type.
        filterType_ = filterType;

        // Check if this log has already been symbolicated (by libsymbolicate).
        isAlreadySymbolicated_ = [[properties_ objectForKey:kCrashReportSymbolicated] boolValue];

        // Parse the file.
        [self parse];
    }
    return self;
}

- (id)initWithFile:(NSString *)filepath {
    return [self initWithFile:filepath filterType:CRCrashReportFilterTypeFile];
}

- (id)initWithFile:(NSString *)filepath filterType:(CRCrashReportFilterType)filterType {
    NSError *error = nil;
    NSData *data = [[NSData alloc] initWithContentsOfFile:filepath options:0 error:&error];
    if (data != nil) {
        return [self initWithData:[data autorelease] filterType:filterType];
    } else {
        fprintf(stderr, "ERROR: Unable to load data from specified file: \"%s\".\n", [[error localizedDescription] UTF8String]);
        [self release];
        return nil;
    }
}

- (void)dealloc {
    [properties_ release];
    [processInfoKeys_ release];
    [processInfoObjects_ release];
    [exception_ release];
    [threads_ release];
    [registerState_ release];
    [binaryImages_ release];
    [super dealloc];
}

#pragma mark - Public API (General)

- (BOOL)blame {
    return [self blameUsingFilters:nil];
}

- (BOOL)blameUsingFilters:(NSDictionary *)filters {
    NSSet *binaryFilters = nil;
    NSSet *exceptionFilters = nil;
    NSSet *functionFilters = nil;
    NSSet *prefixFilters = nil;
    NSSet *reverseFilters = nil;

    // Load blame filters.
    if (filterType_ == CRCrashReportFilterTypeFile) {
        NSDictionary *whitelisted = [filters objectForKey:@"Whitelisted"];
        NSDictionary *blacklisted = [filters objectForKey:@"Blacklisted"];
        binaryFilters = [[NSSet alloc] initWithArray:[whitelisted objectForKey:@"Binaries"]];
        exceptionFilters = [[NSSet alloc] initWithArray:[whitelisted objectForKey:@"Exceptions"]];
        functionFilters = [[NSSet alloc] initWithArray:[whitelisted objectForKey:@"Functions"]];
        prefixFilters = [[NSSet alloc] initWithArray:[whitelisted objectForKey:@"BinaryPathPrefixes"]];
        reverseFilters = [[NSSet alloc] initWithArray:[blacklisted objectForKey:@"Functions"]];
    }

    NSDictionary *binaryImages = [self binaryImages];

    // If exception type is not white-listed, process blame.
    // NOTE: Exception filters variable may be nil; conditional will pass.
    CRException *exception = [self exception];
    if (![exceptionFilters containsObject:[exception type]]) {
        // Mark which binary images are unblamable.
        for (NSNumber *key in binaryImages) {
            CRBinaryImage *binaryImage = [binaryImages objectForKey:key];

            // Determine if binary image should not be blamed.
            BOOL blamable = YES;
            if ([[binaryImage binaryInfo] isFromSharedCache]) {
                // Don't blame anything from the shared cache.
                blamable = NO;
            } else {
                if (filterType_ == CRCrashReportFilterTypeFile) {
                    // Don't blame white-listed binaries (e.g. libraries).
                    NSString *path = [binaryImage path];
                    if ([binaryFilters containsObject:path]) {
                        blamable = NO;
                    } else {
                        // Don't blame white-listed folders.
                        for (NSString *prefix in prefixFilters) {
                            if ([path hasPrefix:prefix]) {
                                blamable = NO;
                                break;
                            }
                        }
                    }
                } else if (filterType_ == CRCrashReportFilterTypePackage) {
                    NSString *path = [binaryImage path];
                    if (![PIDebianPackage isFromDebianPackage:path]) {
                        blamable = NO;
                    }
                }
            }
            [binaryImage setBlamable:blamable];
        }

        // Update the description to reflect any changes in blamability.
        [self updateDescription];

        // Retrieve the thread that crashed
        CRThread *crashedThread = nil;
        for (CRThread *thread in [self threads]) {
            if ([thread crashed]) {
                crashedThread = thread;
                break;
            }
        }

        // Determine blame.
        NSMutableArray *blame = [NSMutableArray new];

        // NOTE: We first look at any exception backtrace, and then the
        //       backtrace of the thread that crashed.
        NSMutableArray *backtraces = [NSMutableArray new];
        NSArray *stackFrames = [[self exception] stackFrames];
        if (stackFrames != nil) {
            [backtraces addObject:stackFrames];
        }
        stackFrames = [crashedThread stackFrames];
        if (stackFrames != nil) {
            [backtraces addObject:stackFrames];
        }
        for (NSArray *stackFrames in backtraces) {
            for (CRStackFrame *stackFrame in stackFrames) {
                // Retrieve info for related binary image.
                NSNumber *imageAddress = [NSNumber numberWithUnsignedLongLong:[stackFrame imageAddress]];
                CRBinaryImage *binaryImage = [binaryImages objectForKey:imageAddress];
                if (binaryImage != nil) {
                    // NOTE: While something in the crashed process may be to blame,
                    //       it itself should not be included in the blame list.
                    // NOTE: The blame list is meant to mark 'external' sources of
                    //       blame.
                    if (![binaryImage isCrashedProcess]) {
                        // Check symbol name of system functions against blame filters.
                        BOOL blamable = [binaryImage isBlamable];
                        NSString *path = [binaryImage path];
                        if (filterType_ == CRCrashReportFilterTypeFile) {
                            if ([path isEqualToString:@"/usr/lib/libSystem.B.dylib"]) {
                                SCSymbolInfo *symbolInfo = [stackFrame symbolInfo];
                                if (symbolInfo != nil) {
                                    NSString *name = [symbolInfo name];
                                    if (name != nil) {
                                        if (blamable) {
                                            // Check if this function should never cause crash (only hang).
                                            if ([functionFilters containsObject:name]) {
                                                blamable = NO;
                                            }
                                        } else {
                                            // Check if this function is actually causing crash.
                                            if ([reverseFilters containsObject:name]) {
                                                blamable = YES;
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Determine if binary image should be blamed.
                        if (blamable) {
                            if (![blame containsObject:path]) {
                                [blame addObject:path];
                            }
                        }
                    }
                }
            }
        }

        // Update the property dictionary.
        NSMutableDictionary *properties = [[NSMutableDictionary alloc] initWithDictionary:[self properties]];
        [properties setObject:blame forKey:kCrashReportBlame];
        [blame release];
        [self setProperties:properties];
        [properties release];
    }

    [binaryFilters release];
    [exceptionFilters release];
    [functionFilters release];
    [prefixFilters release];
    [reverseFilters release];

    // NOTE: Currently, this always 'succeeds'.
    return YES;
}

- (NSString *)stringRepresentation {
    return [self stringRepresentation:[self isPropertyList]];
}

- (NSString *)stringRepresentation:(BOOL)asPropertyList {
    NSString *result = nil;

    if (asPropertyList) {
        // Generate property list string.
        NSError *error = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:[self properties] format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
        if (data != nil) {
            result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        } else {
            fprintf(stderr, "ERROR: Unable to convert report to data: \"%s\".\n", [[error localizedDescription] UTF8String]);
        }
    } else {
        // Generate IPS string.
        Class $NSJSONSerialization = NSClassFromString(@"NSJSONSerialization");
        if ($NSJSONSerialization == nil) {
            fprintf(stderr, "ERROR: This version of iOS does not include NSJSONSerialization, which is required for creating IPS files.\n");
            [self release];
            return nil;
        }

        NSDictionary *properties = [self properties];
        NSMutableDictionary *header = [[NSMutableDictionary alloc] initWithDictionary:properties];
        [header removeObjectForKey:kCrashReportDescription];
        NSString *description = [properties objectForKey:kCrashReportDescription];

        NSError *error = nil;
        NSData *data = [$NSJSONSerialization dataWithJSONObject:header options:0 error:&error];
        if (data != nil) {
            NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            result = [[NSString alloc] initWithFormat:@"%@\n%@", string, description];
            [string release];
        } else {
            fprintf(stderr, "ERROR: Unable to convert report to data: \"%s\".\n", [[error localizedDescription] UTF8String]);
        }
        [header release];
    }

    return [result autorelease];
}

- (BOOL)symbolicate {
    return [self symbolicateUsingSystemRoot:nil symbolMaps:nil];
}

- (BOOL)symbolicateUsingSystemRoot:(NSString *)systemRoot symbolMaps:(NSDictionary *)symbolMaps {
    CRException *exception = [self exception];
    NSDictionary *binaryImages = [self binaryImages];

    // Prepare array of image start addresses for determining symbols of exception.
    NSArray *imageAddresses = nil;
    NSArray *stackFrames = [exception stackFrames];
    if ([stackFrames count] > 0) {
        imageAddresses = [[binaryImages allKeys] sortedArrayUsingSelector:@selector(compare:)];
    }

    // Create symbolicator.
    SCSymbolicator *symbolicator = [SCSymbolicator sharedInstance];

    // Set architecture to use.
    for (CRBinaryImage *binaryImage in [binaryImages allValues]) {
        if ([[binaryImage path] isEqualToString:@"/usr/lib/dyld"]) {
            [symbolicator setArchitecture:[binaryImage architecture]];
            break;
        }
    }

    // Set system root to use.
    if (systemRoot != nil) {
        [symbolicator setSystemRoot:systemRoot];
    }

    // Set symbol maps to use.
    if (symbolMaps != nil) {
        [symbolicator setSymbolMaps:symbolMaps];
    }

    // Symbolicate the exception (if backtrace exists).
    for (CRStackFrame *stackFrame in stackFrames) {
        // Determine start address for this frame.
        if ([stackFrame imageAddress] == 0) {
            for (NSNumber *number in [imageAddresses reverseObjectEnumerator]) {
                uint64_t imageAddress = [number unsignedLongLongValue];
                if ([stackFrame address] > imageAddress) {
                    [stackFrame setImageAddress:imageAddress];
                    break;
                }
            }
        }
        [self symbolicateStackFrame:stackFrame symbolicator:symbolicator];
    }

    // Symbolicate the threads.
    for (CRThread *thread in [self threads]) {
        for (CRStackFrame *stackFrame in [thread stackFrames]) {
            [self symbolicateStackFrame:stackFrame symbolicator:symbolicator];
        }
    }

    // Update the description in order to include symbol info.
    [self updateDescription];

    // Mark this report as "symbolicated".
    NSMutableDictionary *properties = [[NSMutableDictionary alloc] initWithDictionary:[self properties]];
    [properties setObject:[NSNumber numberWithBool:YES] forKey:kCrashReportSymbolicated];
    [self setProperties:properties];
    [properties release];

    // NOTE: Currently, this always 'succeeds'.
    return YES;
}

#pragma mark - Public API (Properties)

- (BOOL)isSymbolicated {
    BOOL isSymbolicated = NO;

    id object = [[self properties] objectForKey:kCrashReportSymbolicated];
    if ([object isKindOfClass:[NSNumber class]]) {
        isSymbolicated = [object boolValue];
    }

    return isSymbolicated;
}

- (NSDictionary *)processInfo {
    return [NSDictionary dictionaryWithObjects:[self processInfoObjects] forKeys:[self processInfoKeys]];
}

#pragma mark - Private Methods

static CRStackFrame *stackFrameWithString(NSString *string) {
    CRStackFrame *stackFrame = nil;
    NSArray *array = [string captureComponentsMatchedByRegex:@"^(\\d+)\\s+.*\\S\\s+(?:0x)?([0-9a-f]+) (?:0x)?([0-9a-f]+) \\+ (?:0x)?\\d+"];
    if ([array count] == 4) {
        NSString *matches[] = {[array objectAtIndex:1], [array objectAtIndex:2], [array objectAtIndex:3]};
        stackFrame = [CRStackFrame new];
        stackFrame.depth = [matches[0] intValue];
        stackFrame.address = uint64FromHexString(matches[1]);
        stackFrame.imageAddress = uint64FromHexString(matches[2]);
    }
    return [stackFrame autorelease];
}

- (void)parse {
    NSString *description = [[self properties] objectForKey:kCrashReportDescription];
    if (description != nil) {
        // Create variables to store parsed information.
        NSMutableArray *processInfoKeys = [NSMutableArray new];
        NSMutableArray *processInfoObjects = [NSMutableArray new];
        CRException *exception = [CRException new];
        NSMutableArray *threads = [NSMutableArray new];
        NSMutableArray *registerState = [NSMutableArray new];
        NSMutableDictionary *binaryImages = [NSMutableDictionary new];
        NSString *processPath = nil;
        CRThread *thread = nil;
        NSString *threadName = nil;

        // NOTE: The description is handled as five separate sections.
        typedef enum {
            ModeProcessInfo,
            ModeException,
            ModeThread,
            ModeRegisterState,
            ModeBinaryImage,
        } SymbolicationMode;

        SymbolicationMode mode = ModeProcessInfo;

        // Process one line at a time.
        NSArray *inputLines = [[description stringByReplacingOccurrencesOfString:@"\r" withString:@""] componentsSeparatedByString:@"\n"];
        for (NSString *line in inputLines) {
            switch (mode) {
                case ModeProcessInfo:
                    if ([line hasPrefix:@"Last Exception Backtrace:"]) {
                        mode = ModeException;
                        break;
                    } else if (![line hasPrefix:@"Thread 0"]) {
                        // Parse process information.
                        NSArray *array = [line captureComponentsMatchedByRegex:@"^([^:]+):\\s*(.*)"];
                        if ([array count] == 3) {
                            NSString *key = [array objectAtIndex:1];
                            NSString *object = [array objectAtIndex:2];
                            [processInfoKeys addObject:key];
                            [processInfoObjects addObject:object];

                            if ([key isEqualToString:@"CrashReporter Key"]) {
                                // Record whether device executing this code is the one that crashed.
                                if ([object isEqualToString:inverseDeviceIdentifier()]) {
                                    processingDeviceIsCrashedDevice_ = YES;
                                }
                            } else if ([key isEqualToString:@"Path"]) {
                                processPath = object;

                                // NOTE: For some reason, the process path
                                //       is sometimes prefixed with multiple '/'
                                //       characters.
                                NSRange range = [processPath rangeOfRegex:@"^/+"];
                                if ((range.location == 0) && (range.length > 1)) {
                                    processPath = [processPath substringFromIndex:(range.length - 1)];
                                }
                            } else if ([key isEqualToString:@"Exception Type"]) {
                                [exception setType:object];
                            }
                        }
                        break;
                    } else {
                        // Start of thread 0.
                        mode = ModeThread;
                        goto parse_thread;
                    }

                case ModeException: {
                    if ([line hasPrefix:@"Thread 0"]) {
                        // Start of thread 0.
                        mode = ModeThread;
                        goto parse_thread;
                    } else {
                        if ([line hasPrefix:@"("] && [line hasSuffix:@")"]) {
                            NSUInteger depth = 0;
                            NSRange range = NSMakeRange(1,  [line length] - 2);
                            NSArray *array = [[line substringWithRange:range] componentsSeparatedByString:@" "];
                            for (NSString *address in array) {
                                CRStackFrame *stackFrame = [CRStackFrame new];
                                stackFrame.depth = depth;
                                stackFrame.address = uint64FromHexString(address);
                                //stackFrame.imageAddress = 0;
                                [exception addStackFrame:stackFrame];
                                [stackFrame release];
                                ++depth;
                            }
                        } else if ([line length] > 0) {
                            CRStackFrame *stackFrame = stackFrameWithString(line);
                            if (stackFrame != nil) {
                                [exception addStackFrame:stackFrame];
                            }
                        }
                    }
                    break;
                }

                case ModeThread:
parse_thread:
                    if ([line rangeOfString:@"Thread State" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        if (thread != nil) {
                            [threads addObject:thread];
                            [thread release];
                        }
                        [registerState addObject:line];
                        mode = ModeRegisterState;
                    } else if ([line length] > 0) {
                        NSRange range = [line rangeOfString:@" name:"];
                        if (range.location != NSNotFound) {
                            threadName = [line substringFromIndex:(range.location + range.length + 2)];
                        } else if ([line hasSuffix:@":"]) {
                            if (thread != nil) {
                                [threads addObject:thread];
                                [thread release];
                            }
                            thread = [CRThread new];
                            if (threadName != nil) {
                                [thread setName:threadName];
                                threadName = nil;
                            }
                            [thread setCrashed:([line rangeOfString:@"Crashed"].location != NSNotFound)];
                        } else {
                            CRStackFrame *stackFrame = stackFrameWithString(line);
                            if (stackFrame != nil) {
                                [thread addStackFrame:stackFrame];
                            }
                        }
                    }
                    break;

                case ModeRegisterState:
                    if ([line hasPrefix:@"Binary Images"]) {
                        mode = ModeBinaryImage;
                    } else if ([line length] > 0) {
                        [registerState addObject:line];
                    }
                    break;

                case ModeBinaryImage: {
                    NSArray *array = [line captureComponentsMatchedByRegex:@"^ *0x([0-9a-f]+) - *0x([0-9a-f]+) [ +]?(?:.+?) (arm\\w*) *(<[0-9a-f]{32}>) *(.+?)(?: \\((.*?) (.*?)\\) \\[(.*?)?\\] \"(.*?)\")?$"];
                    NSUInteger count = [array count];
                    if (count == 10) {
                        uint64_t imageAddress = uint64FromHexString([array objectAtIndex:1]);
                        uint64_t size = uint64FromHexString([array objectAtIndex:2]) - imageAddress;
                        NSString *architecture = [array objectAtIndex:3];
                        NSString *uuid = [array objectAtIndex:4];
                        NSString *path = [array objectAtIndex:5];

                        CRBinaryImage *binaryImage = [[CRBinaryImage alloc] initWithPath:path address:imageAddress architecture:architecture uuid:uuid];
                        [binaryImage setSize:size];
                        if ([path isEqualToString:processPath]) {
                            [binaryImage setCrashedProcess:YES];
                        }

                        // If already symbolicated, capture any previously
                        // recorded debian package information.
                        if (isAlreadySymbolicated_) {
                            NSMutableDictionary *packageDetails = [[NSMutableDictionary alloc] init];

                            // Store package details.
                            NSString *string;
                            string = [array objectAtIndex:6];
                            if ([string length] > 0) {
                                [packageDetails setObject:string forKey:@"Package"];
                            }
                            string = [array objectAtIndex:7];
                            if ([string length] > 0) {
                                [packageDetails setObject:string forKey:@"Version"];
                            }
                            string = [array objectAtIndex:9];
                            if ([string length] > 0) {
                                [packageDetails setObject:string forKey:@"Name"];
                            }

                            // Store package install date.
                            string = [array objectAtIndex:8];
                            if ([string length] > 0) {
                                struct tm time;
                                const char *format = "%Y-%m-%d %H:%M:%S %z";
                                if (strptime([string UTF8String], format, &time) != NULL) {
                                    NSDate *date = [[NSDate alloc] initWithTimeIntervalSince1970:mktime(&time)];
                                    if (date != nil) {
                                        [packageDetails setObject:date forKey:@"InstallDate"];
                                        [date release];
                                    }
                                } else {
                                    fprintf(stderr, "WARNING: Unable to parse date: \"%s\".\n", [string UTF8String]);
                                }
                            }

                            PIDebianPackage *package = [[PIDebianPackage alloc] initWithPackageDetails:packageDetails];
                            [packageDetails release];

                            [[PIPackageCache sharedCache] cachePackage:package forFile:path];
                            [package release];
                        }
                        [binaryImages setObject:binaryImage forKey:[NSNumber numberWithUnsignedLongLong:imageAddress]];
                        [binaryImage release];
                    }
                    break;
                }
            }
        }

        [self setProcessInfoKeys:processInfoKeys];
        [self setProcessInfoObjects:processInfoObjects];
        [self setException:exception];
        [self setThreads:threads];
        [self setRegisterState:registerState];
        [self setBinaryImages:binaryImages];
        [processInfoKeys release];
        [processInfoObjects release];
        [exception release];
        [threads release];
        [registerState release];
        [binaryImages release];
    }
}

- (void)symbolicateStackFrame:(CRStackFrame *)stackFrame symbolicator:(SCSymbolicator *)symbolicator {
    // Retrieve symbol info from related binary image.
    NSNumber *imageAddress = [NSNumber numberWithUnsignedLongLong:[stackFrame imageAddress]];
    CRBinaryImage *binaryImage = [[self binaryImages] objectForKey:imageAddress];
    if (binaryImage != nil) {
        SCSymbolInfo *symbolInfo = [symbolicator symbolInfoForAddress:[stackFrame address] inBinary:[binaryImage binaryInfo]];
        [stackFrame setSymbolInfo:symbolInfo];
    }
}

static void addBinaryImageToDescription(CRBinaryImage *binaryImage, NSMutableString *description) {
    uint64_t imageAddress = [binaryImage address];
    NSString *path = [binaryImage path];
    NSString *string = [[NSString alloc] initWithFormat:@"0x%08llx - 0x%08llx %@ %@  %@ %@",
             imageAddress, imageAddress + [binaryImage size], [path lastPathComponent], [binaryImage architecture], [binaryImage uuid], path];
    [description appendString:string];
    [string release];
}

- (void)updateDescription {
    NSMutableString *description = [NSMutableString new];

    // Add process information.
    NSArray *processInfoKeys = [self processInfoKeys];
    NSArray *processInfoObjects = [self processInfoObjects];
    NSUInteger count = [processInfoKeys count];
    for (NSUInteger i = 0; i < count; ++i) {
        NSString *key = [processInfoKeys objectAtIndex:i];
        NSString *object = [processInfoObjects objectAtIndex:i];

        NSString *keyString = [[NSString alloc] initWithFormat:@"%@:", key];
        NSString *string = [[NSString alloc] initWithFormat:@"%-21s%@\n", [keyString UTF8String], object];
        [description appendString:string];
        [string release];
        [keyString release];
    }

    [description appendString:@"\n"];

    // Add exception.
    NSDictionary *binaryImages = [self binaryImages];
    NSString *string = [[self exception] stringRepresentationUsingBinaryImages:binaryImages];
    if ([string length] > 0) {
        [description appendString:@"Last Exception Backtrace:\n"];
        [description appendString:string];
        [description appendString:@"\n"];
    }

    // Add threads.
    NSArray *threads = [self threads];
    NSUInteger threadCount = [threads count];
    for (NSUInteger i = 0; i < threadCount; ++i) {
        CRThread *thread = [threads objectAtIndex:i];

        // Add thread title.
        NSString *name = [thread name];
        if (name != nil) {
            NSString *string = [[NSString alloc] initWithFormat:@"Thread %lu name:  %@", (unsigned long)i, name];
            [description appendString:string];
            [description appendString:@"\n"];
            [string release];
        }
        NSMutableString *string = [[NSMutableString alloc] initWithFormat:@"Thread %lu", (unsigned long)i];
        if ([thread crashed]) {
            [string appendString:@" Crashed"];
        }
        [string appendString:@":"];
        [description appendString:string];
        [description appendString:@"\n"];
        [string release];

        // Add stack frames of backtrace.
        [description appendString:[thread stringRepresentationUsingBinaryImages:binaryImages]];
        [description appendString:@"\n"];
    }

    // Add register state.
    [description appendString:[[self registerState] componentsJoinedByString:@"\n"]];
    [description appendString:@"\n"];
    [description appendString:@"\n"];

    // Retrieve sorted array of binary image addresses.
    NSArray *imageAddresses = [[binaryImages allKeys] sortedArrayUsingSelector:@selector(compare:)];

    if (filterType_ == CRCrashReportFilterTypeFile) {
        // Add blamable binary images.
        [description appendString:@"Binary Images (Blamable):\n"];
        for (NSString *key in imageAddresses) {
            CRBinaryImage *binaryImage = [binaryImages objectForKey:key];
            if ([binaryImage isBlamable]) {
                addBinaryImageToDescription(binaryImage, description);
                [description appendString:@"\n"];
            }
        }
        [description appendString:@"\n"];

        // Add filtered binary images.
        [description appendString:@"Binary Images (Filtered):\n"];
        for (NSString *key in imageAddresses) {
            CRBinaryImage *binaryImage = [binaryImages objectForKey:key];
            if (![binaryImage isBlamable]) {
                addBinaryImageToDescription(binaryImage, description);
                [description appendString:@"\n"];
            }
        }
    } else if (filterType_ == CRCrashReportFilterTypePackage) {
        NSMutableSet *usedImages = [NSMutableSet new];

        // Add binary images installed via dpkg.
        [description appendString:@"Binary Images (dpkg):\n"];
        for (NSString *key in imageAddresses) {
            CRBinaryImage *binaryImage = [binaryImages objectForKey:key];
            NSString *path = [binaryImage path];

            if ([PIDebianPackage isFromDebianPackage:path]) {
                addBinaryImageToDescription(binaryImage, description);

                // Add package information, if available.
                PIPackage *package = [[PIPackageCache sharedCache] packageForFile:path];
                if (package != nil) {
                    // Add package identifier and version.
                    NSString *identifier = [package identifier];
                    NSString *version = [package version];
                    NSString *string = [[NSString alloc] initWithFormat:@" (%@ %@)",
                            identifier ?: @"<unknown package>",
                            version ?: @"<unknown version>"];
                    [description appendString:string];
                    [string release];

                    // Add install date.
                    [description appendString:@" ["];
                    if (processingDeviceIsCrashedDevice_) {
                        NSDate *installDate = [package installDate];
                        if (installDate != nil) {
                            // Format the date.
                            char buf[29];
                            const char *format = "%Y-%m-%d %H:%M:%S %z";
                            time_t interval = (time_t)[installDate timeIntervalSince1970];
                            if (strftime(buf, 29, format, gmtime(&interval)) > 0) {
                                // Append to line.
                                NSString *string = [[NSString alloc] initWithCString:buf encoding:NSUTF8StringEncoding];
                                [description appendString:string];
                                [string release];
                            } else {
                                fprintf(stderr, "WARNING: Unable to format time interval: \"%ld\".\n", interval);
                            }
                        }
                    }
                    [description appendString:@"]"];

                    // Add package name.
                    NSString *name = [package name];
                    string = [[NSString alloc] initWithFormat:@" \"%@\"",
                            name ?: @"<unknown name>"];
                    [description appendString:string];
                    [string release];
                }

                [description appendString:@"\n"];
                [usedImages addObject:binaryImage];
            }
        }
        [description appendString:@"\n"];

        // Add binary images installed via App Store.
        [description appendString:@"Binary Images (App Store):\n"];
        for (NSString *key in imageAddresses) {
            CRBinaryImage *binaryImage = [binaryImages objectForKey:key];
            if ([[binaryImage path] hasPrefix:@"/var/mobile/Applications/"]) {
                addBinaryImageToDescription(binaryImage, description);
                [description appendString:@"\n"];
                [usedImages addObject:binaryImage];
            }
        }
        [description appendString:@"\n"];

        // Add binary images included with firmware.
        [description appendString:@"Binary Images (Other):\n"];
        for (NSString *key in imageAddresses) {
            CRBinaryImage *binaryImage = [binaryImages objectForKey:key];
            if (![usedImages containsObject:binaryImage]) {
                addBinaryImageToDescription(binaryImage, description);
                [description appendString:@"\n"];
            }
        }

        [usedImages release];
    } else {
        [description appendString:@"Binary Images:\n"];
        for (NSString *key in imageAddresses) {
            CRBinaryImage *binaryImage = [binaryImages objectForKey:key];
            addBinaryImageToDescription(binaryImage, description);
            [description appendString:@"\n"];
        }
    }

    // Update the property dictionary.
    NSMutableDictionary *properties = [[NSMutableDictionary alloc] initWithDictionary:[self properties]];
    [properties setObject:description forKey:kCrashReportDescription];
    [description release];
    [self setProperties:properties];
    [properties release];
}

@end

/* vim: set ft=objcpp ff=unix sw=4 ts=4 tw=80 expandtab: */
