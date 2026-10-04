// QEOverlay.h
// ---------------------------------------------------------------------------
// 精简悬浮窗: 抓到的签名明文直接显示在屏幕上, 一键复制。
// 由 QELog() 调用 QEOverlayAppend() 追加内容。
// ---------------------------------------------------------------------------

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 追加一条记录到悬浮窗 (内部自动切主线程 + 异步, 可安全在任意上下文调用)
void QEOverlayAppend(NSString *title, NSString *body);

/// 幂等创建/重挂载悬浮窗。App 启动早期窗口还没建好时调用直接返回。
void QEOverlayEnsure(void);

NS_ASSUME_NONNULL_END
