export THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = PrankCam
PrankCam_FILES = Tweak.xm
PrankCam_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreImage MediaToolbox AudioToolbox PhotosUI UniformTypeIdentifiers
PrankCam_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/tweak.mk
