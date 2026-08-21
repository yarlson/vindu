#include "VinduBorderEngine.h"
#include "WindowServerSymbols.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <float.h>
#include <math.h>
#include <mach/mach.h>
#include <mach/ndr.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    VBEEventWindowClose = 804,
    VBEEventWindowMove = 806,
    VBEEventWindowResize = 807,
    VBEEventWindowReorder = 808,
    VBEEventWindowLevel = 811,
    VBEEventWindowUnhide = 815,
    VBEEventWindowHide = 816,
    VBEEventWindowDestroy = 1326,
    VBEEventSpaceChange = 1401,
};

static const uint32_t VBEEvents[] = {
    VBEEventWindowClose,
    VBEEventWindowMove,
    VBEEventWindowResize,
    VBEEventWindowReorder,
    VBEEventWindowLevel,
    VBEEventWindowUnhide,
    VBEEventWindowHide,
    VBEEventWindowDestroy,
    VBEEventSpaceChange,
};

struct VBEEngine {
    VBEWindowServerSymbols ws;
    int mainConnection;
    int surfaceConnection;
    CFMachPortRef eventPort;
    CFRunLoopSourceRef eventSource;
    CFRunLoopTimerRef spaceUpdateTimer;
    size_t registeredEventCount;
    uint32_t surfaceWindow;
    uint32_t targetWindow;
    uint64_t targetSpace;
    CGContextRef context;
    CGRect surfaceBounds;
    CGRect targetBounds;
    double surfaceScale;
    double drawnRadius;
    VBEColor *colors;
    size_t colorCount;
    double angleDegrees;
    double width;
    double fallbackRadius;
    bool available;
    bool visible;
    bool needsRedraw;
    bool failureReported;
};

static void updateBorder(VBEEngine *engine);

static void disableEngine(VBEEngine *engine, const char *reason) {
    engine->available = false;
    if (!engine->failureReported) {
        fprintf(stderr, "[vindu] border unavailable — %s\n", reason);
        engine->failureReported = true;
    }
}

static CFArrayRef createWindowArray(uint32_t window) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault,
                                        kCFNumberSInt32Type,
                                        &window);
    if (!number) {
        return NULL;
    }
    const void *values[] = {number};
    CFArrayRef array = CFArrayCreate(kCFAllocatorDefault,
                                     values,
                                     1,
                                     &kCFTypeArrayCallBacks);
    CFRelease(number);
    return array;
}

static bool validRect(CGRect rect) {
    return isfinite(rect.origin.x)
        && isfinite(rect.origin.y)
        && isfinite(rect.size.width)
        && isfinite(rect.size.height)
        && isfinite(CGRectGetMaxX(rect))
        && isfinite(CGRectGetMaxY(rect))
        && rect.size.width > 0
        && rect.size.height > 0;
}

static bool calculateBorderBounds(CGRect target, double width, CGRect *result) {
    if (!validRect(target) || !isfinite(width) || width <= 0) {
        return false;
    }
    CGRect bounds = CGRectInset(target, -width, -width);
    if (!validRect(bounds)) {
        return false;
    }
    *result = bounds;
    return true;
}

static bool orderOut(VBEEngine *engine) {
    if (!engine->surfaceWindow) {
        engine->visible = false;
        return true;
    }
    bool success = engine->ws.setWindowAlpha(engine->surfaceConnection,
                                             engine->surfaceWindow,
                                             0.0f) == kCGErrorSuccess;
    CFTypeRef transaction = engine->ws.transactionCreate(engine->mainConnection);
    if (transaction) {
        engine->ws.transactionOrderWindow(transaction,
                                          engine->surfaceWindow,
                                          0,
                                          engine->targetWindow);
        engine->ws.transactionCommit(transaction, 0);
        CFRelease(transaction);
    }
    engine->visible = false;
    return success;
}

static void cancelSpaceUpdate(VBEEngine *engine) {
    if (!engine->spaceUpdateTimer) {
        return;
    }
    CFRunLoopTimerInvalidate(engine->spaceUpdateTimer);
    CFRelease(engine->spaceUpdateTimer);
    engine->spaceUpdateTimer = NULL;
}

static void spaceUpdateTimerFired(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    VBEEngine *engine = context;
    cancelSpaceUpdate(engine);
    if (engine->available) {
        updateBorder(engine);
    }
}

static bool scheduleSpaceUpdate(VBEEngine *engine) {
    cancelSpaceUpdate(engine);
    CFRunLoopTimerContext context = {0, engine, NULL, NULL, NULL};
    engine->spaceUpdateTimer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                                    CFAbsoluteTimeGetCurrent() + 0.02,
                                                    0,
                                                    0,
                                                    0,
                                                    spaceUpdateTimerFired,
                                                    &context);
    if (!engine->spaceUpdateTimer) {
        return false;
    }
    CFRunLoopAddTimer(CFRunLoopGetMain(),
                      engine->spaceUpdateTimer,
                      kCFRunLoopDefaultMode);
    return true;
}

static void releaseSurface(VBEEngine *engine) {
    orderOut(engine);
    if (engine->context) {
        CGContextRelease(engine->context);
        engine->context = NULL;
    }
    if (engine->surfaceWindow) {
        engine->ws.releaseWindow(engine->surfaceConnection, engine->surfaceWindow);
        engine->surfaceWindow = 0;
    }
    engine->surfaceBounds = CGRectZero;
    engine->targetBounds = CGRectZero;
    engine->surfaceScale = 0;
    engine->targetSpace = 0;
}

static void failBorder(VBEEngine *engine, const char *reason) {
    releaseSurface(engine);
    disableEngine(engine, reason);
}

static void hideBorder(VBEEngine *engine) {
    if (!orderOut(engine)) {
        failBorder(engine, "the WindowServer rejected hiding the border");
    }
}

static double displayScale(CGRect windowBounds) {
    CGDirectDisplayID display = 0;
    uint32_t count = 0;
    CGPoint center = CGPointMake(CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds));
    if (CGGetDisplaysWithPoint(center, 1, &display, &count) != kCGErrorSuccess || count == 0) {
        return 1.0;
    }
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) {
        return 1.0;
    }
    size_t pixels = CGDisplayModeGetPixelWidth(mode);
    CGDisplayModeRelease(mode);
    double points = CGRectGetWidth(CGDisplayBounds(display));
    return points > 0 ? (double)pixels / points : 1.0;
}

static bool configureShadow(VBEEngine *engine) {
    int value = 0;
    CFNumberRef density = CFNumberCreate(kCFAllocatorDefault,
                                         kCFNumberIntType,
                                         &value);
    if (!density) {
        return false;
    }
    const void *keys[] = {CFSTR("com.apple.WindowShadowDensity")};
    const void *values[] = {density};
    CFDictionaryRef properties = CFDictionaryCreate(kCFAllocatorDefault,
                                                     keys,
                                                     values,
                                                     1,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
    CFRelease(density);
    if (!properties) {
        return false;
    }
    CGError error = engine->ws.setWindowShadowProperties(engine->surfaceWindow, properties);
    CFRelease(properties);
    return error == kCGErrorSuccess;
}

static bool createSurface(VBEEngine *engine, CGRect bounds, double scale) {
    if (!validRect(bounds) || !isfinite(scale) || scale <= 0) {
        return false;
    }
    CGRect localBounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    CFTypeRef region = NULL;
    if (engine->ws.newRegionWithRect(&localBounds, &region) != kCGErrorSuccess || !region) {
        return false;
    }
    uint32_t window = 0;
    CGError error = engine->ws.newWindow(engine->surfaceConnection,
                                         kCGBackingStoreBuffered,
                                         -9999,
                                         -9999,
                                         region,
                                         &window);
    CFRelease(region);
    if (error != kCGErrorSuccess || !window) {
        return false;
    }
    engine->surfaceWindow = window;
    engine->surfaceBounds = localBounds;
    engine->surfaceScale = scale;

    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    if (engine->ws.setWindowTags(engine->surfaceConnection, window, &tags, 64) != kCGErrorSuccess
        || engine->ws.setWindowResolution(engine->surfaceConnection, window, scale) != kCGErrorSuccess
        || engine->ws.setWindowOpacity(engine->surfaceConnection, window, false) != kCGErrorSuccess
        || engine->ws.setWindowAlpha(engine->surfaceConnection, window, 0.0f) != kCGErrorSuccess
        || !configureShadow(engine)) {
        releaseSurface(engine);
        return false;
    }
    engine->context = engine->ws.windowContextCreate(engine->surfaceConnection, window, NULL);
    if (!engine->context) {
        releaseSurface(engine);
        return false;
    }
    CGContextSetInterpolationQuality(engine->context, kCGInterpolationNone);
    return true;
}

static bool resizeSurface(VBEEngine *engine, CGRect bounds, double scale) {
    if (!validRect(bounds)
        || !isfinite(scale)
        || scale <= 0
        || fabs(bounds.origin.x) > FLT_MAX
        || fabs(bounds.origin.y) > FLT_MAX) {
        return false;
    }
    CGRect localBounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    if (engine->surfaceScale != scale) {
        releaseSurface(engine);
        return createSurface(engine, bounds, scale);
    }
    if (CGRectEqualToRect(localBounds, engine->surfaceBounds)) {
        return true;
    }
    CFTypeRef region = NULL;
    if (engine->ws.newRegionWithRect(&localBounds, &region) != kCGErrorSuccess || !region) {
        return false;
    }
    CGError error = engine->ws.setWindowShape(engine->surfaceConnection,
                                               engine->surfaceWindow,
                                               (float)bounds.origin.x,
                                               (float)bounds.origin.y,
                                               region);
    CFRelease(region);
    if (error != kCGErrorSuccess) {
        return false;
    }
    engine->surfaceBounds = localBounds;
    return true;
}

static bool copyWindowDetails(VBEEngine *engine, int *level, double *radius) {
    CFArrayRef windowList = createWindowArray(engine->targetWindow);
    if (!windowList) {
        return false;
    }
    CFTypeRef query = engine->ws.windowQuery(engine->mainConnection, windowList, 0);
    CFRelease(windowList);
    if (!query) {
        return false;
    }
    CFTypeRef iterator = engine->ws.windowQueryCopyWindows(query);
    CFRelease(query);
    if (!iterator) {
        return false;
    }
    bool found = engine->ws.windowIteratorAdvance(iterator);
    if (found) {
        *level = engine->ws.windowIteratorLevel(iterator);
        *radius = engine->fallbackRadius;
        if (engine->ws.windowIteratorCornerRadii) {
            CFArrayRef radii = engine->ws.windowIteratorCornerRadii(iterator);
            if (radii && CFArrayGetCount(radii) > 0) {
                CFNumberRef value = (CFNumberRef)CFArrayGetValueAtIndex(radii, 0);
                double actual = 0;
                if (CFNumberGetValue(value, kCFNumberDoubleType, &actual) && actual >= 0) {
                    *radius = actual;
                }
            }
            if (radii) {
                CFRelease(radii);
            }
        }
    }
    CFRelease(iterator);
    return found;
}

static bool copyWindowSpace(VBEEngine *engine,
                            int connection,
                            uint32_t window,
                            uint64_t *space) {
    CFArrayRef windowList = createWindowArray(window);
    if (!windowList) {
        return false;
    }
    CFArrayRef spaces = engine->ws.copySpacesForWindows(connection,
                                                        0x7,
                                                        windowList);
    CFRelease(windowList);
    if (!spaces || CFArrayGetCount(spaces) == 0) {
        if (spaces) {
            CFRelease(spaces);
        }
        return false;
    }
    CFNumberRef value = (CFNumberRef)CFArrayGetValueAtIndex(spaces, 0);
    bool copied = CFNumberGetValue(value, kCFNumberSInt64Type, space);
    CFRelease(spaces);
    return copied && *space != 0;
}

static bool copyWindowSubLevel(VBEEngine *engine, int *subLevel) {
    if (__builtin_available(macOS 26.0, *)) {
        #pragma pack(push, 2)
        struct {
            struct {
                mach_msg_header_t header;
                NDR_record_t ndr;
            } request;
            struct {
                int32_t window;
            } payload;
            struct {
                int32_t value;
                int64_t padding;
            } response;
        } message = {0};
        #pragma pack(pop)

        message.request.ndr = NDR_record;
        message.request.header.msgh_remote_port = engine->ws.serverPort(NULL);
        message.request.header.msgh_local_port = engine->ws.specialReplyPort();
        message.request.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND,
                                                               MACH_MSG_TYPE_MAKE_SEND_ONCE,
                                                               0,
                                                               MACH_MSGH_BITS_REMOTE_MASK);
        message.request.header.msgh_id = 0x76e3;
        message.payload.window = (int32_t)engine->targetWindow;
        kern_return_t result = mach_msg(&message.request.header,
                                        MACH_SEND_MSG | MACH_SEND_SYNC_OVERRIDE
                                            | MACH_SEND_PROPAGATE_QOS | MACH_RCV_MSG
                                            | MACH_RCV_SYNC_WAIT,
                                        sizeof(message.request) + sizeof(message.payload),
                                        sizeof(message),
                                        message.request.header.msgh_local_port,
                                        MACH_MSG_TIMEOUT_NONE,
                                        MACH_PORT_NULL);
        if (result != KERN_SUCCESS) {
            engine->ws.deallocateSpecialReplyPort(message.request.header.msgh_local_port);
            return false;
        }
        if (message.request.header.msgh_id != 0x7747) {
            mach_msg_destroy(&message.request.header);
            return false;
        }
        *subLevel = message.response.value;
        return true;
    }
    *subLevel = engine->ws.getWindowSubLevel(engine->mainConnection,
                                             engine->targetWindow);
    return true;
}

static bool moveSurfaceToSpace(VBEEngine *engine, uint64_t space) {
    if (engine->targetSpace == space) {
        return true;
    }
    CFArrayRef surfaceList = createWindowArray(engine->surfaceWindow);
    if (!surfaceList) {
        return false;
    }
    engine->ws.moveWindowsToSpace(engine->surfaceConnection, surfaceList, space);
    CFRelease(surfaceList);
    uint64_t actualSpace = 0;
    if (!copyWindowSpace(engine,
                         engine->surfaceConnection,
                         engine->surfaceWindow,
                         &actualSpace)
        || actualSpace != space) {
        return false;
    }
    engine->targetSpace = space;
    return true;
}

static bool drawBorder(VBEEngine *engine, double radius) {
    CGRect bounds = engine->surfaceBounds;
    CGRect inner = CGRectInset(bounds, engine->width, engine->width);
    CGMutablePathRef ring = CGPathCreateMutable();
    if (!ring || !validRect(bounds) || !validRect(inner) || !isfinite(radius)) {
        if (ring) {
            CGPathRelease(ring);
        }
        return false;
    }
    double innerRadius = fmin(fmax(0, radius),
                              fmin(inner.size.width, inner.size.height) / 2);
    double outerRadius = innerRadius + engine->width;
    if (!isfinite(innerRadius) || !isfinite(outerRadius)) {
        CGPathRelease(ring);
        return false;
    }
    CGPathAddRoundedRect(ring, NULL, bounds, outerRadius, outerRadius);
    CGPathAddRoundedRect(ring, NULL, inner, innerRadius, innerRadius);

    if (engine->colorCount == 1) {
        CGContextSaveGState(engine->context);
        CGContextClearRect(engine->context, bounds);
        CGContextAddPath(engine->context, ring);
        CGContextEOClip(engine->context);
        VBEColor color = engine->colors[0];
        CGContextSetRGBFillColor(engine->context,
                                 color.red,
                                 color.green,
                                 color.blue,
                                 color.alpha);
        CGContextFillRect(engine->context, bounds);
        CGContextRestoreGState(engine->context);
        CGContextFlush(engine->context);
        CGError error = engine->ws.flushWindowContent(engine->surfaceConnection,
                                                      engine->surfaceWindow,
                                                      NULL);
        CGPathRelease(ring);
        return error == kCGErrorSuccess;
    }

    size_t componentCount = engine->colorCount * 4;
    CGFloat *components = calloc(componentCount, sizeof(CGFloat));
    CGFloat *locations = calloc(engine->colorCount, sizeof(CGFloat));
    if (!components || !locations) {
        free(components);
        free(locations);
        CGPathRelease(ring);
        return false;
    }
    for (size_t index = 0; index < engine->colorCount; index++) {
        components[index * 4] = engine->colors[index].red;
        components[index * 4 + 1] = engine->colors[index].green;
        components[index * 4 + 2] = engine->colors[index].blue;
        components[index * 4 + 3] = engine->colors[index].alpha;
        locations[index] = engine->colorCount == 1
            ? 0
            : (CGFloat)index / (CGFloat)(engine->colorCount - 1);
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = colorSpace
        ? CGGradientCreateWithColorComponents(colorSpace,
                                               components,
                                               locations,
                                               engine->colorCount)
        : NULL;
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }
    free(components);
    free(locations);
    if (!gradient) {
        CGPathRelease(ring);
        return false;
    }

    CGContextSaveGState(engine->context);
    CGContextClearRect(engine->context, bounds);
    CGContextAddPath(engine->context, ring);
    CGContextEOClip(engine->context);
    double radians = remainder(engine->angleDegrees, 360.0) * M_PI / 180.0;
    double x = cos(radians);
    double y = sin(radians);
    double distance = fabs(x) * bounds.size.width + fabs(y) * bounds.size.height;
    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGPoint start = CGPointMake(center.x - x * distance / 2,
                                center.y - y * distance / 2);
    CGPoint end = CGPointMake(center.x + x * distance / 2,
                              center.y + y * distance / 2);
    if (!isfinite(distance)
        || !isfinite(center.x)
        || !isfinite(center.y)
        || !isfinite(start.x)
        || !isfinite(start.y)
        || !isfinite(end.x)
        || !isfinite(end.y)) {
        CGContextRestoreGState(engine->context);
        CGPathRelease(ring);
        CGGradientRelease(gradient);
        return false;
    }
    CGContextDrawLinearGradient(engine->context,
                                gradient,
                                start,
                                end,
                                kCGGradientDrawsBeforeStartLocation
                                    | kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(engine->context);
    CGContextFlush(engine->context);
    CGError error = engine->ws.flushWindowContent(engine->surfaceConnection,
                                                  engine->surfaceWindow,
                                                  NULL);
    CGPathRelease(ring);
    CGGradientRelease(gradient);
    return error == kCGErrorSuccess;
}

static bool orderSurface(VBEEngine *engine,
                         CGRect targetBounds,
                         int level,
                         int subLevel) {
    if (!validRect(targetBounds)) {
        return false;
    }
    CGPoint origin = CGPointMake(targetBounds.origin.x - engine->width,
                                 targetBounds.origin.y - engine->width);
    if (!isfinite(origin.x) || !isfinite(origin.y)) {
        return false;
    }
    CFTypeRef transaction = engine->ws.transactionCreate(engine->mainConnection);
    if (!transaction) {
        return false;
    }
    engine->ws.transactionMoveWindow(transaction, engine->surfaceWindow, origin);
    CGAffineTransform transform = CGAffineTransformIdentity;
    transform.tx = -origin.x;
    transform.ty = -origin.y;
    engine->ws.transactionSetTransform(transaction,
                                       engine->surfaceWindow,
                                       0,
                                       0,
                                       transform);
    engine->ws.transactionSetLevel(transaction, engine->surfaceWindow, level);
    engine->ws.transactionSetSubLevel(transaction, engine->surfaceWindow, subLevel);
    engine->ws.transactionOrderWindow(transaction,
                                      engine->surfaceWindow,
                                      -1,
                                      engine->targetWindow);
    engine->ws.transactionCommit(transaction, 0);
    CFRelease(transaction);
    return engine->ws.setWindowAlpha(engine->surfaceConnection,
                                     engine->surfaceWindow,
                                     1.0f) == kCGErrorSuccess;
}

static bool moveSurface(VBEEngine *engine, CGRect targetBounds) {
    if (!validRect(targetBounds)) {
        return false;
    }
    CGPoint origin = CGPointMake(targetBounds.origin.x - engine->width,
                                 targetBounds.origin.y - engine->width);
    if (!isfinite(origin.x) || !isfinite(origin.y)) {
        return false;
    }
    CFTypeRef transaction = engine->ws.transactionCreate(engine->mainConnection);
    if (!transaction) {
        return false;
    }
    engine->ws.transactionMoveWindow(transaction, engine->surfaceWindow, origin);
    engine->ws.transactionCommit(transaction, 0);
    CFRelease(transaction);
    return true;
}

static void moveBorder(VBEEngine *engine) {
    CGRect targetBounds = CGRectZero;
    if (!engine->visible
        || engine->ws.getWindowBounds(engine->mainConnection,
                                      engine->targetWindow,
                                      &targetBounds) != kCGErrorSuccess
        || !validRect(targetBounds)
        || targetBounds.size.width != engine->targetBounds.size.width
        || targetBounds.size.height != engine->targetBounds.size.height
        || displayScale(targetBounds) != engine->surfaceScale) {
        updateBorder(engine);
        return;
    }
    if (!moveSurface(engine, targetBounds)) {
        failBorder(engine, "the WindowServer rejected a border move");
        return;
    }
    engine->targetBounds = targetBounds;
}

static void resizeBorder(VBEEngine *engine) {
    CGRect targetBounds = CGRectZero;
    if (!engine->visible
        || engine->ws.getWindowBounds(engine->mainConnection,
                                      engine->targetWindow,
                                      &targetBounds) != kCGErrorSuccess
        || !validRect(targetBounds)
        || displayScale(targetBounds) != engine->surfaceScale) {
        updateBorder(engine);
        return;
    }
    CGRect borderBounds = CGRectZero;
    if (!calculateBorderBounds(targetBounds, engine->width, &borderBounds)) {
        hideBorder(engine);
        return;
    }
    CGRect localBounds = CGRectMake(0, 0, borderBounds.size.width, borderBounds.size.height);
    if (CGRectEqualToRect(localBounds, engine->surfaceBounds)) {
        moveBorder(engine);
        return;
    }
    if (!resizeSurface(engine, borderBounds, engine->surfaceScale)
        || !moveSurface(engine, targetBounds)
        || !drawBorder(engine, engine->drawnRadius)) {
        failBorder(engine, "the WindowServer rejected a border resize");
        return;
    }
    engine->targetBounds = targetBounds;
}

static void updateBorder(VBEEngine *engine) {
    if (!engine->available || !engine->targetWindow || engine->width <= 0
        || engine->colorCount == 0) {
        hideBorder(engine);
        return;
    }
    bool ordered = false;
    CGRect targetBounds = CGRectZero;
    int level = 0;
    int subLevel = 0;
    double radius = engine->fallbackRadius;
    uint64_t space = 0;
    if (engine->ws.windowIsOrderedIn(engine->mainConnection,
                                     engine->targetWindow,
                                     &ordered) != kCGErrorSuccess
        || !ordered
        || engine->ws.getWindowBounds(engine->mainConnection,
                                      engine->targetWindow,
                                      &targetBounds) != kCGErrorSuccess
        || !validRect(targetBounds)
        || !copyWindowDetails(engine, &level, &radius)
        || !copyWindowSubLevel(engine, &subLevel)
        || !copyWindowSpace(engine,
                            engine->mainConnection,
                            engine->targetWindow,
                            &space)) {
        hideBorder(engine);
        return;
    }

    CGRect borderBounds = CGRectZero;
    if (!calculateBorderBounds(targetBounds, engine->width, &borderBounds)) {
        hideBorder(engine);
        return;
    }
    double scale = displayScale(targetBounds);
    if (!isfinite(scale) || scale <= 0) {
        hideBorder(engine);
        return;
    }
    CGRect localBounds = CGRectMake(0, 0, borderBounds.size.width, borderBounds.size.height);
    bool needsResize = !engine->surfaceWindow
        || engine->surfaceScale != scale
        || !CGRectEqualToRect(localBounds, engine->surfaceBounds);
    bool needsDrawing = needsResize || engine->needsRedraw || engine->drawnRadius != radius;
    const char *failure = NULL;
    bool ready = needsResize
        ? (engine->surfaceWindow
            ? resizeSurface(engine, borderBounds, scale)
            : createSurface(engine, borderBounds, scale))
        : true;
    if (!ready) {
        failure = "the WindowServer rejected the border surface";
    } else if (!moveSurfaceToSpace(engine, space)) {
        ready = false;
        failure = "the WindowServer rejected border Space membership";
    } else if (needsDrawing && !drawBorder(engine, radius)) {
        ready = false;
        failure = "the WindowServer rejected border drawing";
    } else if (!orderSurface(engine, targetBounds, level, subLevel)) {
        ready = false;
        failure = "the WindowServer rejected border ordering";
    }
    if (!ready) {
        failBorder(engine, failure);
        return;
    }
    engine->visible = true;
    engine->needsRedraw = false;
    engine->drawnRadius = radius;
    engine->targetBounds = targetBounds;
}

static void windowEvent(uint32_t event, void *data, size_t length, void *context) {
    VBEEngine *engine = context;
    if (!engine || !engine->available) {
        return;
    }
    if (event == VBEEventSpaceChange) {
        hideBorder(engine);
        if (!engine->available) {
            return;
        }
        if (!scheduleSpaceUpdate(engine)) {
            failBorder(engine, "cannot schedule a border Space update");
        }
        return;
    }
    if (!data || length < sizeof(uint32_t)) {
        return;
    }
    uint32_t window = 0;
    if (event == VBEEventWindowDestroy) {
        size_t windowOffset = sizeof(uint64_t);
        if (length < windowOffset + sizeof(window)) {
            return;
        }
        memcpy(&window, (const unsigned char *)data + windowOffset, sizeof(window));
    } else {
        memcpy(&window, data, sizeof(window));
    }
    if (window != engine->targetWindow) {
        return;
    }
    if (event == VBEEventWindowHide
        || event == VBEEventWindowClose
        || event == VBEEventWindowDestroy) {
        hideBorder(engine);
        return;
    }
    if (event == VBEEventWindowMove) {
        moveBorder(engine);
        return;
    }
    if (event == VBEEventWindowResize) {
        resizeBorder(engine);
        return;
    }
    updateBorder(engine);
}

static void drainEvents(CFMachPortRef port,
                        void *message,
                        CFIndex size,
                        void *context) {
    (void)port;
    (void)message;
    (void)size;
    VBEEngine *engine = context;
    if (!engine || !engine->available) {
        return;
    }
    CGEventRef event = engine->ws.nextEvent(engine->mainConnection);
    while (event) {
        CFRelease(event);
        event = engine->ws.nextEvent(engine->mainConnection);
    }
}

static bool registerEvents(VBEEngine *engine) {
    for (size_t index = 0; index < sizeof(VBEEvents) / sizeof(VBEEvents[0]); index++) {
        if (engine->ws.registerNotify(windowEvent,
                                      VBEEvents[index],
                                      engine) != kCGErrorSuccess) {
            return false;
        }
        engine->registeredEventCount++;
    }
    mach_port_t port = MACH_PORT_NULL;
    if (engine->ws.getEventPort(engine->mainConnection, &port) != kCGErrorSuccess
        || port == MACH_PORT_NULL) {
        return false;
    }
    CFMachPortContext context = {0, engine, NULL, NULL, NULL};
    engine->eventPort = CFMachPortCreateWithPort(kCFAllocatorDefault,
                                                 port,
                                                 drainEvents,
                                                 &context,
                                                 NULL);
    if (!engine->eventPort) {
        return false;
    }
    engine->ws.setMachPortOptions(engine->eventPort, 0x40);
    engine->eventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                        engine->eventPort,
                                                        0);
    if (!engine->eventSource) {
        return false;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), engine->eventSource, kCFRunLoopDefaultMode);
    return true;
}

static bool unregisterEvents(VBEEngine *engine) {
    if (engine->eventSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              engine->eventSource,
                              kCFRunLoopDefaultMode);
        CFRelease(engine->eventSource);
        engine->eventSource = NULL;
    }
    if (engine->eventPort) {
        CFMachPortInvalidate(engine->eventPort);
        CFRelease(engine->eventPort);
        engine->eventPort = NULL;
    }
    while (engine->registeredEventCount > 0) {
        size_t index = engine->registeredEventCount - 1;
        if (engine->ws.removeNotify(windowEvent,
                                    VBEEvents[index],
                                    engine) != kCGErrorSuccess) {
            return false;
        }
        engine->registeredEventCount--;
    }
    return true;
}

VBEEngine *VBEEngineCreate(void) {
    VBEEngine *engine = calloc(1, sizeof(*engine));
    if (!engine) {
        fprintf(stderr, "[vindu] border unavailable — cannot allocate the border engine\n");
        return NULL;
    }
    char failure[160] = {0};
    if (!VBEWindowServerSymbolsLoad(&engine->ws, failure, sizeof(failure))) {
        disableEngine(engine, failure);
        return engine;
    }
    engine->mainConnection = engine->ws.mainConnectionID();
    if (!engine->mainConnection
        || engine->ws.newConnection(0, &engine->surfaceConnection) != kCGErrorSuccess
        || !engine->surfaceConnection
        || !registerEvents(engine)) {
        disableEngine(engine, "cannot initialize WindowServer events");
        if (unregisterEvents(engine)) {
            if (engine->surfaceConnection) {
                engine->ws.releaseConnection(engine->surfaceConnection);
                engine->surfaceConnection = 0;
            }
            VBEWindowServerSymbolsUnload(&engine->ws);
        }
        return engine;
    }
    engine->available = true;
    return engine;
}

void VBEEngineSetTarget(VBEEngine *engine,
                        uint32_t windowID,
                        const VBEColor *colors,
                        size_t colorCount,
                        double angleDegrees,
                        double width,
                        double fallbackRadius) {
    if (!engine || !engine->available) {
        return;
    }
    if (!windowID || !colors || colorCount == 0 || width <= 0) {
        VBEEngineHide(engine);
        return;
    }
    if (!isfinite(angleDegrees) || !isfinite(width) || !isfinite(fallbackRadius)
        || colorCount > SIZE_MAX / sizeof(VBEColor)) {
        VBEEngineHide(engine);
        return;
    }
    for (size_t index = 0; index < colorCount; index++) {
        if (!isfinite(colors[index].red)
            || !isfinite(colors[index].green)
            || !isfinite(colors[index].blue)
            || !isfinite(colors[index].alpha)) {
            VBEEngineHide(engine);
            return;
        }
    }
    bool sameColors = engine->colorCount == colorCount
        && engine->colors
        && memcmp(engine->colors, colors, colorCount * sizeof(VBEColor)) == 0;
    if (!sameColors) {
        VBEColor *copiedColors = calloc(colorCount, sizeof(VBEColor));
        if (!copiedColors) {
            failBorder(engine, "cannot allocate the border gradient");
            return;
        }
        memcpy(copiedColors, colors, colorCount * sizeof(VBEColor));
        free(engine->colors);
        engine->colors = copiedColors;
        engine->colorCount = colorCount;
    }
    double normalizedRadius = fmax(0, fallbackRadius);
    bool styleChanged = !sameColors
        || engine->angleDegrees != angleDegrees
        || engine->width != width
        || engine->fallbackRadius != normalizedRadius;
    bool targetChanged = engine->targetWindow != windowID;
    engine->angleDegrees = angleDegrees;
    engine->width = width;
    engine->fallbackRadius = normalizedRadius;
    engine->needsRedraw = engine->needsRedraw || styleChanged || targetChanged;
    if (targetChanged) {
        engine->targetWindow = windowID;
        engine->targetSpace = 0;
        if (engine->ws.requestNotifications(engine->mainConnection,
                                            &windowID,
                                            1) != kCGErrorSuccess) {
            failBorder(engine, "cannot subscribe to target window events");
            return;
        }
    }
    updateBorder(engine);
}

void VBEEngineHide(VBEEngine *engine) {
    if (!engine) {
        return;
    }
    cancelSpaceUpdate(engine);
    hideBorder(engine);
    engine->targetWindow = 0;
    engine->targetSpace = 0;
    engine->targetBounds = CGRectZero;
}

void VBEEngineDestroy(VBEEngine *engine) {
    if (!engine) {
        return;
    }
    engine->available = false;
    cancelSpaceUpdate(engine);
    if (engine->ws.handle) {
        bool unregistered = unregisterEvents(engine);
        releaseSurface(engine);
        if (engine->surfaceConnection) {
            engine->ws.releaseConnection(engine->surfaceConnection);
            engine->surfaceConnection = 0;
        }
        free(engine->colors);
        engine->colors = NULL;
        engine->colorCount = 0;
        if (!unregistered) {
            return;
        }
        VBEWindowServerSymbolsUnload(&engine->ws);
    }
    free(engine->colors);
    free(engine);
}
