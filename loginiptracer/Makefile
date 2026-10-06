ARCHS = arm64
TARGET = iphone:clang:latest:12.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LoginIPTracer

LoginIPTracer_FILES = src/LoginIPTracer.m
LoginIPTracer_CFLAGS = -Oz -fno-stack-protector -fno-builtin -Wno-empty-body
LoginIPTracer_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
