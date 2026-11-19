export THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = PrankCamPro
PrankCamPro_FILES = Tweak.xm
PrankCamPro_FRAMEWORKS = Foundation UIKit QuartzCore CoreGraphics AVFoundation CoreMedia CoreVideo CoreImage MediaToolbox AudioToolbox PhotosUI UniformTypeIdentifiers
PrankCamPro_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/tweak.mk
