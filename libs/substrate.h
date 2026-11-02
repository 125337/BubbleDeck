#ifndef SUBSTRATE_H
#define SUBSTRATE_H

#include <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

void MSHookMessageEx(Class _class, SEL sel, IMP replacement, IMP *result);

#ifdef __cplusplus
}
#endif

#endif
