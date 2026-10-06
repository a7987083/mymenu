ARCHS = arm64
TARGET = iphone:clang:latest:12.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LoginTCPPayload

LoginTCPPayload_FILES = src/LoginTCPPayload.m vendor/fishhook.c
LoginTCPPayload_CFLAGS = -Oz -fno-stack-protector -fno-builtin -fblocks -Wno-deprecated-declarations -Wno-unguarded-availability-new
LoginTCPPayload_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
