// Copyright 2026 Unity Technologies
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

#include "handler/unity_post_minidump_hook.h"

namespace crashpad {

void (*UnityCrashpadPostMinidumpHook)(const base::FilePath& database_path,
                                     const UUID& report_id,
                                     task_t crashed_task) = nullptr;

}  // namespace crashpad
