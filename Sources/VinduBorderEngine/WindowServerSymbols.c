#include "WindowServerSymbols.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static bool loadSymbol(void *handle,
                       const char *name,
                       void **destination,
                       char *failure,
                       size_t failureSize) {
    *destination = dlsym(handle, name);
    if (*destination) {
        return true;
    }
    snprintf(failure, failureSize, "missing WindowServer symbol %s", name);
    return false;
}

#define LOAD(field, name) \
    if (!loadSymbol(symbols->handle, name, (void **)&symbols->field, failure, failureSize)) { \
        VBEWindowServerSymbolsUnload(symbols); \
        return false; \
    }

bool VBEWindowServerSymbolsLoad(VBEWindowServerSymbols *symbols,
                                char *failure,
                                size_t failureSize) {
    memset(symbols, 0, sizeof(*symbols));
    symbols->handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                             RTLD_LAZY | RTLD_LOCAL);
    if (!symbols->handle) {
        snprintf(failure, failureSize, "cannot open the WindowServer framework");
        return false;
    }

    LOAD(mainConnectionID, "SLSMainConnectionID");
    LOAD(newConnection, "SLSNewConnection");
    LOAD(releaseConnection, "SLSReleaseConnection");
    LOAD(getEventPort, "SLSGetEventPort");
    LOAD(nextEvent, "SLEventCreateNextEvent");
    LOAD(setMachPortOptions, "_CFMachPortSetOptions");
    LOAD(registerNotify, "SLSRegisterNotifyProc");
    LOAD(removeNotify, "SLSRemoveNotifyProc");
    LOAD(requestNotifications, "SLSRequestNotificationsForWindows");
    LOAD(getWindowBounds, "SLSGetWindowBounds");
    LOAD(windowIsOrderedIn, "SLSWindowIsOrderedIn");
    LOAD(newRegionWithRect, "CGSNewRegionWithRect");
    LOAD(newWindow, "SLSNewWindow");
    LOAD(releaseWindow, "SLSReleaseWindow");
    LOAD(setWindowTags, "SLSSetWindowTags");
    LOAD(setWindowShape, "SLSSetWindowShape");
    LOAD(setWindowResolution, "SLSSetWindowResolution");
    LOAD(setWindowOpacity, "SLSSetWindowOpacity");
    LOAD(setWindowAlpha, "SLSSetWindowAlpha");
    LOAD(setWindowShadowProperties, "SLSWindowSetShadowProperties");
    LOAD(windowContextCreate, "SLWindowContextCreate");
    LOAD(flushWindowContent, "SLSFlushWindowContentRegion");
    LOAD(transactionCreate, "SLSTransactionCreate");
    LOAD(transactionMoveWindow, "SLSTransactionMoveWindowWithGroup");
    LOAD(transactionSetLevel, "SLSTransactionSetWindowLevel");
    LOAD(transactionSetSubLevel, "SLSTransactionSetWindowSubLevel");
    LOAD(transactionSetTransform, "SLSTransactionSetWindowTransform");
    LOAD(transactionOrderWindow, "SLSTransactionOrderWindow");
    LOAD(transactionCommit, "SLSTransactionCommit");
    LOAD(windowQuery, "SLSWindowQueryWindows");
    LOAD(windowQueryCopyWindows, "SLSWindowQueryResultCopyWindows");
    LOAD(windowIteratorAdvance, "SLSWindowIteratorAdvance");
    LOAD(windowIteratorLevel, "SLSWindowIteratorGetLevel");
    LOAD(copySpacesForWindows, "SLSCopySpacesForWindows");
    LOAD(moveWindowsToSpace, "SLSMoveWindowsToManagedSpace");
    LOAD(getWindowSubLevel, "SLSGetWindowSubLevel");
    LOAD(serverPort, "SLSServerPort");
    LOAD(specialReplyPort, "mig_get_special_reply_port");
    LOAD(deallocateSpecialReplyPort, "mig_dealloc_special_reply_port");

    void *cornerRadiusSymbol = dlsym(symbols->handle,
                                     "SLSWindowIteratorGetCornerRadii");
    memcpy(&symbols->windowIteratorCornerRadii,
           &cornerRadiusSymbol,
           sizeof(cornerRadiusSymbol));
    return true;
}

void VBEWindowServerSymbolsUnload(VBEWindowServerSymbols *symbols) {
    if (symbols->handle) {
        dlclose(symbols->handle);
    }
    memset(symbols, 0, sizeof(*symbols));
}
