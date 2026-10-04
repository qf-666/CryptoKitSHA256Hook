ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CryptoKitSHA256Hook

# Tweak.x 已摘除: 它的 fishhook rebind (CC_SHA256/ccdigest) 会拦下**全系统**
# 的哈希调用 (UIKit/CFNetwork/BSDescriptionBuilder/GDTMobSDK 全都调),
# 然后在这些系统路径内部创建 ObjC 对象 (NSString/NSMutableData/NSLog/description),
# 破坏 CFString 的 in-mutation 状态 → 下一个 appendFormat: 撞 mutateError → abort。
# 崩溃报告 (133051 os_state / 180742 GDT / 181016 FlowLayout NSLog) 都证明
# 崩溃路径与我们的 ObjC hook 无关, 是 rebind 的副作用。
# 签名明文已由 Tweak_qeuser_sign.m 的 stringWithFormat: 那层覆盖, 不需要它。
CryptoKitSHA256Hook_FILES = Tweak_qeuser_sign.m fishhook.c
CryptoKitSHA256Hook_CFLAGS = -fobjc-arc
CryptoKitSHA256Hook_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
