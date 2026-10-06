ARCHS = arm64
TARGET = iphone:clang:latest:12.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LoginHTTPObserver

LoginHTTPObserver_FILES = src/LoginHTTPObserver.m
LoginHTTPObserver_CFLAGS = -Oz -fno-stack-protector -fno-builtin -fblocks -Wno-deprecated-declarations -Wno-unguarded-availability-new
LoginHTTPObserver_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
