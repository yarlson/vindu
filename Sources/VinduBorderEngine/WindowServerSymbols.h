#ifndef VINDU_WINDOW_SERVER_SYMBOLS_H
#define VINDU_WINDOW_SERVER_SYMBOLS_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*VBEWindowEventCallback)(uint32_t, void *, uint32_t, void *);

typedef struct {
    void *handle;
    int (*mainConnectionID)(void);
    CGError (*newConnection)(int, int *);
    CGError (*releaseConnection)(int);
    CGError (*getEventPort)(int, mach_port_t *);
    CGEventRef (*nextEvent)(int);
    void (*setMachPortOptions)(CFMachPortRef, int);
    CGError (*registerNotify)(VBEWindowEventCallback, uint32_t, void *);
    CGError (*removeNotify)(VBEWindowEventCallback, uint32_t, void *);
    CGError (*requestNotifications)(int, uint32_t *, int);
    CGError (*getWindowBounds)(int, uint32_t, CGRect *);
    CGError (*windowIsOrderedIn)(int, uint32_t, bool *);
    CGError (*newRegionWithRect)(CGRect *, CFTypeRef *);
    CGError (*newWindow)(int, int, float, float, CFTypeRef, uint32_t *);
    CGError (*releaseWindow)(int, uint32_t);
    CGError (*setWindowTags)(int, uint32_t, uint64_t *, int);
    CGError (*setWindowShape)(int, uint32_t, float, float, CFTypeRef);
    CGError (*setWindowResolution)(int, uint32_t, double);
    CGError (*setWindowOpacity)(int, uint32_t, bool);
    CGError (*setWindowAlpha)(int, uint32_t, float);
    CGError (*setWindowShadowProperties)(uint32_t, CFDictionaryRef);
    CGContextRef (*windowContextCreate)(int, uint32_t, CFDictionaryRef);
    CGError (*flushWindowContent)(int, uint32_t, void *);
    CFTypeRef (*transactionCreate)(int);
    CGError (*transactionMoveWindow)(CFTypeRef, uint32_t, CGPoint);
    CGError (*transactionSetLevel)(CFTypeRef, uint32_t, int);
    CGError (*transactionSetSubLevel)(CFTypeRef, uint32_t, int);
    CGError (*transactionSetTransform)(CFTypeRef,
                                       uint32_t,
                                       int,
                                       int,
                                       CGAffineTransform);
    CGError (*transactionOrderWindow)(CFTypeRef, uint32_t, int, uint32_t);
    CGError (*transactionCommit)(CFTypeRef, int);
    CFTypeRef (*windowQuery)(int, CFArrayRef, uint32_t);
    CFTypeRef (*windowQueryCopyWindows)(CFTypeRef);
    bool (*windowIteratorAdvance)(CFTypeRef);
    int (*windowIteratorLevel)(CFTypeRef);
    CFArrayRef (*windowIteratorCornerRadii)(CFTypeRef);
    CFArrayRef (*copySpacesForWindows)(int, int, CFArrayRef);
    void (*moveWindowsToSpace)(int, CFArrayRef, uint64_t);
    int32_t (*getWindowSubLevel)(int, uint32_t);
    mach_port_t (*serverPort)(void *);
    mach_port_t (*specialReplyPort)(void);
    void (*deallocateSpecialReplyPort)(mach_port_t);
} VBEWindowServerSymbols;

bool VBEWindowServerSymbolsLoad(VBEWindowServerSymbols *symbols,
                                char *failure,
                                size_t failureSize);
void VBEWindowServerSymbolsUnload(VBEWindowServerSymbols *symbols);

#endif
