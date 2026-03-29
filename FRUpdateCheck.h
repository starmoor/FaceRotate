// 联网检查更新：定期拉取最新版本号（结果存偏好 uc.latest），同时上报本机版本信息。
// 失败静默重试，绝不影响主功能；%ctor 末尾调用 FRUpdateCheckStart 即可。
// Tweak.xm 是 ObjC++（符号 mangling），FRUpdateCheck.m 是 ObjC——extern "C" 必须带。

#pragma once

#include <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void FRUpdateCheckStart(void);

#ifdef __cplusplus
}
#endif
