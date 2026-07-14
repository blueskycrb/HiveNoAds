TARGET := iphone:clang:latest:13.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = HiveConsumer

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HiveNoAds

HiveNoAds_FILES = Tweak.x
HiveNoAds_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
HiveNoAds_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
