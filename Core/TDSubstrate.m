//
//  TDSubstrate.m
//  BubbleDeck
//
//  使用纯 ObjC Runtime 实现 MSHookMessageEx，消除对 CydiaSubstrate/libsubstrate.dylib 的依赖。
//  （移植自 MioPlugin/Core/MioSubstrate.m，验证过的实现。）
//

#import <objc/runtime.h>
#import <objc/message.h>

#ifdef __cplusplus
extern "C" {
#endif

void MSHookMessageEx(Class _class, SEL _sel, IMP _imp, IMP *_result) {
    // ── 参数保护 ──
    if (!_class || !_sel || !_imp) return;

    // ── 获取原始 Method（沿继承链查找，可能在父类上）──
    Method m = class_getInstanceMethod(_class, _sel);
    if (!m) return;

    IMP origIMP = method_getImplementation(m);

    // ── 关键安全处理 ──
    // 方法不在 _class 本身上（在父类）时，直接 method_setImplementation 会改父类实现。
    // 先 class_addMethod 把原始 IMP 复制到 _class，再替换 _class 上的实现。
    if (!class_addMethod(_class, _sel, origIMP, method_getTypeEncoding(m))) {
        method_setImplementation(m, _imp);
    } else {
        class_replaceMethod(_class, _sel, _imp, method_getTypeEncoding(m));
    }

    // ── 返回原始 IMP（对应 MSHookMessageEx 的第四个参数 &orig_xxx）──
    if (_result) {
        *_result = origIMP;
    }
}

#ifdef __cplusplus
}
#endif
