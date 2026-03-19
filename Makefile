ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CryptoKitSHA256Hook

CryptoKitSHA256Hook_FILES = Tweak.x
CryptoKitSHA256Hook_CFLAGS = -fobjc-arc
CryptoKitSHA256Hook_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
