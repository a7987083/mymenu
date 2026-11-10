ARCHS = arm64
TARGET = iphone:clang:latest:14.0
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyMenuCustomer
MyMenuCustomer_FILES = ZNCustomerMenu.mm ZNCustomerAdapter.mm ../iosruntimepatchmenu/src/ZNStaticDispatchRuntime.mm ../iosruntimepatchmenu/src/ZNStaticRVAProtection.mm ../iosruntimepatchmenu/src/ZNPatchCore.mm
MyMenuCustomer_CFLAGS = -fobjc-arc -fblocks -std=c++17 -Werror=return-type
MyMenuCustomer_FRAMEWORKS = UIKit QuartzCore Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
