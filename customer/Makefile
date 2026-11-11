ARCHS = arm64
TARGET = iphone:clang:latest:14.0
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyMenuCustomer
MyMenuCustomer_FILES = ZNCustomerMenu.mm ZNCustomerAdapter.mm ZNCustomerCatalog.mm ZNCustomerReceiverLifecycle.mm ../iosruntimepatchmenu/src/ZNStaticDispatchRuntime.mm ../iosruntimepatchmenu/src/ZNStaticRVAProtection.mm ../iosruntimepatchmenu/src/ZNPatchCore.mm ../iosruntimepatchmenu/src/ZNIL2CPPResolver.mm ../iosruntimepatchmenu/src/ZNRuntimeActionRuntime.mm ../iosruntimepatchmenu/src/ZNRuntimeActionModel.mm ../iosruntimepatchmenu/src/ZNIL2CPPInvokeEngine.mm ../iosruntimepatchmenu/src/ZNIL2CPPMethodSignature.mm ../iosruntimepatchmenu/src/ZNIL2CPPABIMetadata.mm ../iosruntimepatchmenu/src/ZNRuntimeArgumentMarshaller.mm ../iosruntimepatchmenu/src/ZNIL2CPPInstanceResolver.mm ../iosruntimepatchmenu/src/ZNIL2CPPInstanceSelectionV2.mm ../iosruntimepatchmenu/src/ZNM462InstanceSafety.mm ../iosruntimepatchmenu/src/ZNValueTypeModel.mm
MyMenuCustomer_CFLAGS = -fobjc-arc -fblocks -std=c++17 -Werror=return-type -Wno-unused-function
MyMenuCustomer_FRAMEWORKS = UIKit QuartzCore Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
