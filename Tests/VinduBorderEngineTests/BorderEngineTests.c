#include <assert.h>
#include <float.h>
#include <stdlib.h>
#include <string.h>

#include "../../Sources/VinduBorderEngine/BorderEngine.c"

typedef struct {
    int registerCalls;
    int registerFailure;
    int removeCalls;
    uint32_t removeFailureEvent;
    uint32_t removedEvents[32];
    void *removedContexts[32];
    int transactionStep;
    int transactionFailureStep;
    int alphaOneCalls;
    CGError alphaResult;
    int releaseWindowCalls;
    int surfaceCalls;
    int unloadCalls;
    CGError flushResult;
} FakeState;

static FakeState fake;

static void resetFake(void) {
    memset(&fake, 0, sizeof(fake));
    fake.registerFailure = -1;
    fake.transactionFailureStep = -1;
    fake.alphaResult = kCGErrorSuccess;
}

static CGError fakeRegister(VBEWindowEventCallback callback, uint32_t event, void *context) {
    assert(callback == windowEvent);
    assert(context != NULL);
    int call = fake.registerCalls++;
    return call == fake.registerFailure ? kCGErrorFailure : kCGErrorSuccess;
}

static CGError fakeRemove(VBEWindowEventCallback callback, uint32_t event, void *context) {
    assert(callback == windowEvent);
    fake.removedEvents[fake.removeCalls] = event;
    fake.removedContexts[fake.removeCalls] = context;
    fake.removeCalls++;
    return event == fake.removeFailureEvent ? kCGErrorFailure : kCGErrorSuccess;
}

static CFTypeRef fakeTransactionCreate(int connection) {
    (void)connection;
    return CFRetain(CFSTR("transaction"));
}

static CGError transactionResult(void) {
    int step = fake.transactionStep++;
    return step == fake.transactionFailureStep ? kCGErrorFailure : kCGErrorSuccess;
}

static CGError fakeTransactionMove(CFTypeRef transaction, uint32_t window, CGPoint point) {
    (void)transaction;
    (void)window;
    (void)point;
    return transactionResult();
}

static CGError fakeTransactionTransform(CFTypeRef transaction,
                                        uint32_t window,
                                        int x,
                                        int y,
                                        CGAffineTransform transform) {
    (void)transaction;
    (void)window;
    (void)x;
    (void)y;
    (void)transform;
    return transactionResult();
}

static CGError fakeTransactionLevel(CFTypeRef transaction, uint32_t window, int level) {
    (void)transaction;
    (void)window;
    (void)level;
    return transactionResult();
}

static CGError fakeTransactionOrder(CFTypeRef transaction,
                                    uint32_t window,
                                    int mode,
                                    uint32_t relativeTo) {
    (void)transaction;
    (void)window;
    (void)mode;
    (void)relativeTo;
    return transactionResult();
}

static CGError fakeTransactionCommit(CFTypeRef transaction, int synchronous) {
    (void)transaction;
    (void)synchronous;
    return transactionResult();
}

static CGError fakeAlpha(int connection, uint32_t window, float alpha) {
    (void)connection;
    (void)window;
    if (alpha == 1.0f) {
        fake.alphaOneCalls++;
    }
    return fake.alphaResult;
}

static CGError fakeFlush(int connection, uint32_t window, void *region) {
    (void)connection;
    (void)window;
    (void)region;
    return fake.flushResult;
}

static CGError fakeReleaseWindow(int connection, uint32_t window) {
    (void)connection;
    (void)window;
    fake.releaseWindowCalls++;
    return kCGErrorSuccess;
}

static CGError fakeNewRegion(CGRect *bounds, CFTypeRef *region) {
    (void)bounds;
    fake.surfaceCalls++;
    *region = CFRetain(CFSTR("region"));
    return kCGErrorSuccess;
}

static CGError fakeSetWindowShape(int connection,
                                  uint32_t window,
                                  float x,
                                  float y,
                                  CFTypeRef region) {
    (void)connection;
    (void)window;
    (void)x;
    (void)y;
    (void)region;
    fake.surfaceCalls++;
    return kCGErrorSuccess;
}

static VBEEngine transactionEngine(void) {
    VBEEngine engine = {0};
    engine.surfaceWindow = 20;
    engine.targetWindow = 10;
    engine.width = 2;
    engine.ws.transactionCreate = fakeTransactionCreate;
    engine.ws.transactionMoveWindow = fakeTransactionMove;
    engine.ws.transactionSetTransform = fakeTransactionTransform;
    engine.ws.transactionSetLevel = fakeTransactionLevel;
    engine.ws.transactionSetSubLevel = fakeTransactionLevel;
    engine.ws.transactionOrderWindow = fakeTransactionOrder;
    engine.ws.transactionCommit = fakeTransactionCommit;
    engine.ws.setWindowAlpha = fakeAlpha;
    engine.ws.releaseWindow = fakeReleaseWindow;
    return engine;
}

static void testRegistrationRollback(void) {
    resetFake();
    VBEEngine engine = {0};
    engine.ws.registerNotify = fakeRegister;
    engine.ws.removeNotify = fakeRemove;
    fake.registerFailure = 3;

    assert(!registerEvents(&engine));
    assert(engine.registeredEventCount == 3);
    assert(unregisterEvents(&engine));
    assert(engine.registeredEventCount == 0);
    assert(fake.removeCalls == 3);
    assert(fake.removedEvents[0] == VBEEvents[2]);
    assert(fake.removedEvents[1] == VBEEvents[1]);
    assert(fake.removedEvents[2] == VBEEvents[0]);
    for (int index = 0; index < fake.removeCalls; index++) {
        assert(fake.removedContexts[index] == &engine);
    }
}

static void testRemovalRetry(void) {
    resetFake();
    VBEEngine engine = {0};
    engine.ws.removeNotify = fakeRemove;
    engine.registeredEventCount = 3;
    fake.removeFailureEvent = VBEEvents[2];

    assert(!unregisterEvents(&engine));
    assert(engine.registeredEventCount == 3);
    fake.removeFailureEvent = 0;
    assert(unregisterEvents(&engine));
    assert(engine.registeredEventCount == 0);
    assert(fake.removedEvents[0] == VBEEvents[2]);
    assert(fake.removedEvents[1] == VBEEvents[2]);
}

static void testDestroyRetainsFailedCallbackContext(void) {
    resetFake();
    VBEEngine *engine = calloc(1, sizeof(*engine));
    assert(engine != NULL);
    engine->available = true;
    engine->ws.handle = engine;
    engine->ws.removeNotify = fakeRemove;
    engine->registeredEventCount = 1;
    fake.removeFailureEvent = VBEEvents[0];

    VBEEngineDestroy(engine);
    assert(fake.unloadCalls == 0);
    assert(!engine->available);
    windowEvent(VBEEventWindowMove, NULL, 0, engine);

    fake.removeFailureEvent = 0;
    VBEEngineDestroy(engine);
    assert(fake.unloadCalls == 1);
}

static void testTransactionFailuresDoNotRaiseSurface(void) {
    CGRect target = CGRectMake(10, 20, 800, 600);
    for (int failure = 0; failure < 6; failure++) {
        resetFake();
        VBEEngine engine = transactionEngine();
        fake.transactionFailureStep = failure;
        assert(!orderSurface(&engine, target, 1, 2));
        assert(fake.transactionStep == failure + 1);
        assert(fake.alphaOneCalls == 0);
    }

    resetFake();
    VBEEngine engine = transactionEngine();
    assert(orderSurface(&engine, target, 1, 2));
    assert(fake.transactionStep == 6);
    assert(fake.alphaOneCalls == 1);

    resetFake();
    engine = transactionEngine();
    fake.alphaResult = kCGErrorFailure;
    assert(!orderSurface(&engine, target, 1, 2));
    assert(fake.transactionStep == 6);

    resetFake();
    engine = transactionEngine();
    engine.visible = true;
    fake.transactionFailureStep = 0;
    assert(!orderOut(&engine));
    assert(fake.transactionStep == 1);

    resetFake();
    engine = transactionEngine();
    engine.visible = true;
    fake.transactionFailureStep = 1;
    assert(!orderOut(&engine));
    assert(fake.transactionStep == 2);

    resetFake();
    engine = transactionEngine();
    engine.available = true;
    engine.failureReported = true;
    fake.alphaResult = kCGErrorFailure;
    hideBorder(&engine);
    assert(!engine.available);
    assert(engine.surfaceWindow == 0);
    assert(fake.releaseWindowCalls == 1);
}

static void testMoveChecksCommit(void) {
    resetFake();
    VBEEngine engine = transactionEngine();
    fake.transactionFailureStep = 1;
    assert(!moveSurface(&engine, CGRectMake(10, 20, 800, 600)));
    assert(fake.transactionStep == 2);
}

static void testGeometryRejectsInvalidDerivedBounds(void) {
    CGRect result = CGRectZero;
    assert(calculateBorderBounds(CGRectMake(0, 0, 800, 600), 2, &result));
    assert(!calculateBorderBounds(CGRectMake(NAN, 0, 800, 600), 2, &result));
    assert(!calculateBorderBounds(CGRectMake(0, 0, 800, 600), INFINITY, &result));
    assert(!calculateBorderBounds(CGRectMake(0, 0, 800, 600), DBL_MAX, &result));
    assert(!validRect(CGRectMake(DBL_MAX, 0, DBL_MAX, 600)));
    VBEEngine engine = {0};
    assert(!createSurface(&engine, CGRectMake(0, 0, 800, 600), NAN));
    engine.surfaceWindow = 1;
    engine.surfaceScale = 1;
    engine.surfaceBounds = CGRectMake(0, 0, 10, 10);
    engine.ws.newRegionWithRect = fakeNewRegion;
    engine.ws.setWindowShape = fakeSetWindowShape;
    assert(!resizeSurface(&engine,
                          CGRectMake((double)FLT_MAX * 2, 0, 20, 20),
                          1));
    assert(fake.surfaceCalls == 0);
    assert(resizeSurface(&engine, CGRectMake(10, 20, 20, 20), 1));
    assert(fake.surfaceCalls == 2);
}

static void testDrawReportsFlushFailureAndHandlesHugeAngle(void) {
    resetFake();
    unsigned char pixels[20 * 20 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels,
                                                 20,
                                                 20,
                                                 8,
                                                 20 * 4,
                                                 space,
                                                 kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    assert(context != NULL);
    VBEColor colors[] = {
        {1, 0, 0, 1},
        {0, 0, 1, 1},
    };
    VBEEngine engine = {0};
    engine.context = context;
    engine.surfaceBounds = CGRectMake(0, 0, 20, 20);
    engine.surfaceWindow = 1;
    engine.width = 2;
    engine.colors = colors;
    engine.colorCount = 2;
    engine.angleDegrees = DBL_MAX;
    engine.ws.flushWindowContent = fakeFlush;

    fake.flushResult = kCGErrorSuccess;
    assert(drawBorder(&engine, 4));
    fake.flushResult = kCGErrorFailure;
    assert(!drawBorder(&engine, 4));
    CGContextRelease(context);
}

bool VBEWindowServerSymbolsLoad(VBEWindowServerSymbols *symbols,
                                char *failure,
                                size_t failureSize) {
    (void)symbols;
    (void)failure;
    (void)failureSize;
    return false;
}

void VBEWindowServerSymbolsUnload(VBEWindowServerSymbols *symbols) {
    fake.unloadCalls++;
    memset(symbols, 0, sizeof(*symbols));
}

int main(void) {
    testRegistrationRollback();
    testRemovalRetry();
    testDestroyRetainsFailedCallbackContext();
    testTransactionFailuresDoNotRaiseSurface();
    testMoveChecksCommit();
    testGeometryRejectsInvalidDerivedBounds();
    testDrawReportsFlushFailureAndHandlesHugeAngle();
    return 0;
}
