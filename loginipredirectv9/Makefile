ARCHS = arm64
TARGET = iphone:clang:latest:12.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LoginIPRedirectV9

LoginIPRedirectV9_FILES = src/LoginIPRedirectV9.m ../logintcppayload/vendor/fishhook.c
LoginIPRedirectV9_CFLAGS = -Oz -fno-stack-protector -fno-builtin -fblocks -Wno-deprecated-declarations -Wno-unguarded-availability-new
LoginIPRedirectV9_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
