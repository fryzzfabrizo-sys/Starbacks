#pragma once
#include "../esp/Core/UnityMath.h"
#include <stdint.h>

void InitMagnetThread();
void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward);
void ResetAimMagnet();
