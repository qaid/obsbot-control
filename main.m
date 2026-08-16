// obsbot: minimal CLI to control an OBSBOT Meet 2 webcam's UVC controls via VVUVCKit.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <VVUVCKit/VVUVCKit.h>

#define OBSBOT_VID 13668
#define OBSBOT_PID 65275

// Find the OBSBOT camera's USB locationID via IOKit. Returns 0 (invalid) if not found.
static UInt32 findOBSBOTLocationID(void) {
    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iter) != KERN_SUCCESS) {
        return 0;
    }

    UInt32 locationID = 0;
    io_service_t device;
    while ((device = IOIteratorNext(iter))) {
        CFNumberRef vendorIDRef = (CFNumberRef)IORegistryEntryCreateCFProperty(device, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        CFNumberRef productIDRef = (CFNumberRef)IORegistryEntryCreateCFProperty(device, CFSTR("idProduct"), kCFAllocatorDefault, 0);

        int vendorID = 0, productID = 0;
        if (vendorIDRef) CFNumberGetValue(vendorIDRef, kCFNumberIntType, &vendorID);
        if (productIDRef) CFNumberGetValue(productIDRef, kCFNumberIntType, &productID);

        BOOL matches = NO;
        if (vendorID == OBSBOT_VID && productID == OBSBOT_PID) {
            matches = YES;
        } else {
            CFStringRef nameRef = (CFStringRef)IORegistryEntryCreateCFProperty(device, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
            if (nameRef) {
                NSString *name = (__bridge NSString *)nameRef;
                if ([name rangeOfString:@"OBSBOT" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [name rangeOfString:@"Meet 2" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    matches = YES;
                }
                CFRelease(nameRef);
            }
        }

        if (matches) {
            CFNumberRef locRef = (CFNumberRef)IORegistryEntryCreateCFProperty(device, CFSTR("locationID"), kCFAllocatorDefault, 0);
            if (locRef) {
                CFNumberGetValue(locRef, kCFNumberSInt32Type, &locationID);
                CFRelease(locRef);
            }
        }

        if (vendorIDRef) CFRelease(vendorIDRef);
        if (productIDRef) CFRelease(productIDRef);
        IOObjectRelease(device);
        if (locationID != 0) break;
    }
    IOObjectRelease(iter);
    return locationID;
}

// Dispatch table entry: friendly name -> selectors for get/set/min/max/supported.
typedef struct {
    const char *name;
    SEL getSel;
    SEL setSel;
    SEL minSel;
    SEL maxSel;
    SEL supSel;
    SEL autoGetSel; // 0 if no auto mode
    SEL autoSetSel; // 0 if no auto mode
} ControlEntry;

static ControlEntry controls[9];
static const int numControls = 9;

// ponytail: @selector() isn't a compile-time constant, so build the table at runtime instead of as a static initializer.
static void initControls(void) {
    int i = 0;
    controls[i++] = (ControlEntry){ "zoom",         @selector(zoom),         @selector(setZoom:),         @selector(minZoom),         @selector(maxZoom),         @selector(zoomSupported),         0, 0 };
    controls[i++] = (ControlEntry){ "focus",        @selector(focus),        @selector(setFocus:),        @selector(minFocus),        @selector(maxFocus),        @selector(focusSupported),        @selector(autoFocus),        @selector(setAutoFocus:) };
    controls[i++] = (ControlEntry){ "exposure",     @selector(exposureTime), @selector(setExposureTime:), @selector(minExposureTime), @selector(maxExposureTime), @selector(exposureTimeSupported), @selector(autoExposureMode), 0 /* special-cased */ };
    controls[i++] = (ControlEntry){ "brightness",   @selector(bright),       @selector(setBright:),       @selector(minBright),       @selector(maxBright),       @selector(brightSupported),       0, 0 };
    controls[i++] = (ControlEntry){ "contrast",     @selector(contrast),     @selector(setContrast:),     @selector(minContrast),     @selector(maxContrast),     @selector(contrastSupported),     0, 0 };
    controls[i++] = (ControlEntry){ "saturation",   @selector(saturation),   @selector(setSaturation:),   @selector(minSaturation),   @selector(maxSaturation),   @selector(saturationSupported),   0, 0 };
    controls[i++] = (ControlEntry){ "sharpness",    @selector(sharpness),    @selector(setSharpness:),    @selector(minSharpness),    @selector(maxSharpness),    @selector(sharpnessSupported),     0, 0 };
    controls[i++] = (ControlEntry){ "gain",         @selector(gain),         @selector(setGain:),         @selector(minGain),         @selector(maxGain),         @selector(gainSupported),         0, 0 };
    controls[i++] = (ControlEntry){ "whitebalance", @selector(whiteBalance), @selector(setWhiteBalance:), @selector(minWhiteBalance), @selector(maxWhiteBalance), @selector(whiteBalanceSupported), @selector(autoWhiteBalance), @selector(setAutoWhiteBalance:) };
}

static ControlEntry *findControl(NSString *name) {
    for (int i = 0; i < numControls; i++) {
        if ([name caseInsensitiveCompare:[NSString stringWithUTF8String:controls[i].name]] == NSOrderedSame) {
            return &controls[i];
        }
    }
    return NULL;
}

static long callLong(VVUVCController *c, SEL sel) {
    NSMethodSignature *sig = [c methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv invokeWithTarget:c];
    long result = 0;
    [inv getReturnValue:&result];
    return result;
}

static void callVoidLong(VVUVCController *c, SEL sel, long val) {
    NSMethodSignature *sig = [c methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv setArgument:&val atIndex:2];
    [inv invokeWithTarget:c];
}

static BOOL callBool(VVUVCController *c, SEL sel) {
    NSMethodSignature *sig = [c methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv invokeWithTarget:c];
    BOOL result = NO;
    [inv getReturnValue:&result];
    return result;
}

static void printUsage(void) {
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  obsbot get\n");
    fprintf(stderr, "  obsbot set <name> <value|auto>\n");
    fprintf(stderr, "  obsbot reset\n");
    fprintf(stderr, "Names: zoom, focus, exposure, brightness, contrast, saturation, sharpness, gain, whitebalance\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            printUsage();
            return 0;
        }

        initControls();
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        UInt32 locationID = findOBSBOTLocationID();
        if (locationID == 0) {
            fprintf(stderr, "Error: no OBSBOT camera found via IOKit.\n");
            return 1;
        }

        VVUVCController *controller = [[VVUVCController alloc] initWithLocationID:locationID];
        if (controller == nil) {
            fprintf(stderr, "Error: failed to open UVC controller for locationID 0x%08X.\n", locationID);
            return 1;
        }

        if ([cmd isEqualToString:@"get"]) {
            for (int i = 0; i < numControls; i++) {
                ControlEntry *e = &controls[i];
                BOOL supported = callBool(controller, e->supSel);
                if (!supported) continue;
                long cur = callLong(controller, e->getSel);
                long lo = callLong(controller, e->minSel);
                long hi = callLong(controller, e->maxSel);
                NSMutableString *line = [NSMutableString stringWithFormat:@"%s: %ld (%ld-%ld)", e->name, cur, lo, hi];
                if (e->autoGetSel != 0) {
                    // ponytail: exposure's "auto" is a mode enum, not a bool; treat non-manual as "auto: yes"
                    if (strcmp(e->name, "exposure") == 0) {
                        UVC_AEMode mode = (UVC_AEMode)callLong(controller, e->autoGetSel);
                        [line appendFormat:@" [auto: %s]", (mode == UVC_AEMode_Manual) ? "no" : "yes"];
                    } else {
                        BOOL isAuto = callBool(controller, e->autoGetSel);
                        [line appendFormat:@" [auto: %s]", isAuto ? "yes" : "no"];
                    }
                }
                printf("%s\n", [line UTF8String]);
            }
            return 0;
        }

        if ([cmd isEqualToString:@"reset"]) {
            [controller resetParamsToDefaults];
            printf("Reset all controls to defaults.\n");
            return 0;
        }

        if ([cmd isEqualToString:@"set"]) {
            if (argc < 4) {
                printUsage();
                return 1;
            }
            NSString *name = [NSString stringWithUTF8String:argv[2]];
            NSString *valStr = [NSString stringWithUTF8String:argv[3]];

            ControlEntry *e = findControl(name);
            if (e == NULL) {
                fprintf(stderr, "Error: unknown control '%s'.\n", argv[2]);
                return 1;
            }

            BOOL supported = callBool(controller, e->supSel);
            if (!supported) {
                fprintf(stderr, "Error: control '%s' is not supported by this camera.\n", e->name);
                return 1;
            }

            if ([valStr caseInsensitiveCompare:@"auto"] == NSOrderedSame) {
                if (strcmp(e->name, "focus") == 0) {
                    callVoidLong(controller, @selector(setAutoFocus:), 1);
                } else if (strcmp(e->name, "whitebalance") == 0) {
                    callVoidLong(controller, @selector(setAutoWhiteBalance:), 1);
                } else if (strcmp(e->name, "exposure") == 0) {
                    [controller setAutoExposureMode:UVC_AEMode_Auto];
                } else {
                    fprintf(stderr, "Error: '%s' has no auto mode.\n", e->name);
                    return 1;
                }
                printf("Set %s to auto.\n", e->name);
                return 0;
            }

            long value = [valStr integerValue];
            long lo = callLong(controller, e->minSel);
            long hi = callLong(controller, e->maxSel);
            long clamped = value;
            if (clamped < lo) clamped = lo;
            if (clamped > hi) clamped = hi;

            callVoidLong(controller, e->setSel, clamped);

            if (clamped != value) {
                printf("Set %s to %ld (clamped from %ld, range %ld-%ld).\n", e->name, clamped, value, lo, hi);
            } else {
                printf("Set %s to %ld.\n", e->name, clamped);
            }
            return 0;
        }

        printUsage();
        return 0;
    }
}
