ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TYPopup

TYPopup_FILES = \
TYPopup.mm \
TYPopupBridge.mm

TYPopup_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
