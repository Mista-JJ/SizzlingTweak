//
//  bypassEnti.m
//
//  Fixes this crash when an app runs inside LiveContainer (re-signed, so it
//  has no Siri entitlement):
//
//    Use of the class INVocabulary requires the entitlement com.apple.developer.siri.
//
//  Intents.framework throws an NSException the first time INVocabulary is used
//  without that entitlement. We swizzle +[INVocabulary sharedVocabulary] (and
//  -[INVocabulary init] as a fallback) to return nil. Messages to nil are no-ops
//  in Objective-C, so the app's later calls such as -setVocabularyStrings:ofType:
//  do nothing instead of throwing. Only Siri vocabulary sync is lost, which
//  could not work without the entitlement anyway.
//
//  Build (Mac with Xcode):
//    xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=14.0 -fobjc-arc \
//      -dynamiclib -framework Foundation bypassEnti.m -o bypassEnti.dylib
//
//  Then add bypassEnti.dylib as a tweak for the app in LiveContainer and relaunch.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define BELog(...) NSLog(@"[bypassEnti] %@", [NSString stringWithFormat:__VA_ARGS__])

#pragma mark - Replacement implementations

// Stands in for +[INVocabulary sharedVocabulary].
static id BE_returnNil(__unused id self, __unused SEL _cmd) {
    return nil;
}

// Stands in for -[INVocabulary init]. init-family methods consume `self`, so tell
// ARC to release it here; otherwise the freshly allocated object would leak.
static id BE_initReturnNil(id __attribute__((ns_consumed)) self, __unused SEL _cmd) {
    return nil;
}

#pragma mark - Swizzling helper

static void BE_swizzle(Class cls, const char *selName, IMP replacement, BOOL isClassMethod) {
    SEL sel = sel_registerName(selName);
    Class target = isClassMethod ? object_getClass(cls) : cls; // class methods live on the metaclass
    const char kind = isClassMethod ? '+' : '-';

    Method original = class_getInstanceMethod(target, sel);
    if (!original) {
        BELog(@"%c[%s %s] not found, skipping", kind, class_getName(cls), selName);
        return;
    }
    const char *types = method_getTypeEncoding(original);

    // The class only inherits this method (e.g. NSObject's -init): add an override
    // on this class alone so the superclass implementation is never touched.
    if (class_addMethod(target, sel, replacement, types)) {
        BELog(@"%c[%s %s] overridden", kind, class_getName(cls), selName);
        return;
    }

    // The class has its own implementation: classic swizzle. The original stays
    // reachable under the prefixed selector.
    NSString *altName = [@"bypassEnti_" stringByAppendingString:[NSString stringWithUTF8String:selName]];
    SEL altSel = sel_registerName(altName.UTF8String);
    if (class_addMethod(target, altSel, replacement, types)) {
        method_exchangeImplementations(original, class_getInstanceMethod(target, altSel));
        BELog(@"%c[%s %s] swizzled", kind, class_getName(cls), selName);
    }
}

#pragma mark - Entry point

__attribute__((constructor))
static void bypassEnti_install(void) {
    @autoreleasepool {
        // Make sure Intents is loaded even if this tweak is injected before the app links it.
        dlopen("/System/Library/Frameworks/Intents.framework/Intents", RTLD_NOW);

        Class vocabulary = objc_getClass("INVocabulary");
        if (!vocabulary) {
            BELog(@"INVocabulary not found, nothing to hook");
            return;
        }

        BE_swizzle(vocabulary, "sharedVocabulary", (IMP)BE_returnNil,     YES); // +[INVocabulary sharedVocabulary]
        BE_swizzle(vocabulary, "init",             (IMP)BE_initReturnNil, NO);  // -[INVocabulary init]
    }
}
