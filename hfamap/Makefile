ARCHS = arm64
TARGET = iphone:clang:latest:12.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HFAMapUniversal

HFAMapUniversal_FILES = src/HFAMapLegacy.m src/HFAMapPatchExecutionTrace.m src/HFAMapSecretCallGraphProbe.m
HFAMapUniversal_CFLAGS = -Oz -fno-stack-protector -fno-builtin -Wno-empty-body
HFAMapUniversal_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
