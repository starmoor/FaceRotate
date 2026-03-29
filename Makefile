ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FaceRotate
FaceRotate_FILES = Tweak.xm FRUpdateCheck.m
FaceRotate_CFLAGS = -fobjc-arc -Os

BUNDLE_NAME = FaceRotatePrefs
FaceRotatePrefs_FILES = FaceRotatePrefs.m FRAppListController.m
FaceRotatePrefs_CFLAGS = -fobjc-arc -Os
FaceRotatePrefs_INSTALL_PATH = /Library/PreferenceBundles
FaceRotatePrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

before-package::
	find "$(THEOS_STAGING_DIR)" -type f \( -name "*.dylib" -o -name "FaceRotatePrefs" \) -exec ldid -S {} +
	sed -e 's/^Package: com\.starmoor\.facerotate$$/Package: com.starmoor.facerotate.$(THEOS_PACKAGE_SCHEME)/' \
	    -e 's/^Name: FaceRotate$$/Name: FaceRotate ($(THEOS_PACKAGE_SCHEME))/' \
	    "$(THEOS_STAGING_DIR)/DEBIAN/control" > "$(THEOS_STAGING_DIR)/DEBIAN/control.tmp" \
	  && mv "$(THEOS_STAGING_DIR)/DEBIAN/control.tmp" "$(THEOS_STAGING_DIR)/DEBIAN/control"

after-install::
	install.exec "killall -9 SpringBoard || true"
