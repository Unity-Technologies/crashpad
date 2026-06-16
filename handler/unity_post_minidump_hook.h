// Copyright 2026 Unity Technologies
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

#ifndef CRASHPAD_HANDLER_UNITY_POST_MINIDUMP_HOOK_H_
#define CRASHPAD_HANDLER_UNITY_POST_MINIDUMP_HOOK_H_

#include "base/files/file_path.h"
#include "util/misc/uuid.h"
#include <mach/mach.h>

namespace crashpad {

//! \brief Optional callback invoked immediately after minidump generation.
//!
//! When building the Unity crash handler, Unity provides the implementation.
//! For standalone Crashpad builds, a nullptr default is provided by
//! unity_post_minidump_hook.cc.
extern void (*UnityCrashpadPostMinidumpHook)(const base::FilePath& database_path,
                                            const UUID& report_id,
                                            task_t crashed_task);

}  // namespace crashpad

#endif  // CRASHPAD_HANDLER_UNITY_POST_MINIDUMP_HOOK_H_
