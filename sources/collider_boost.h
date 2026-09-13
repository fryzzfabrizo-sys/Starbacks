// collider_boost.h
#pragma once
#include <stdint.h>

// Автоматически читается из NSUserDefaults по ключу "BoostHitbox".
// Поток запускается при загрузке dylib через __attribute__((constructor)).
// Ручной вызов не требуется.
void ColliderBoostStart(void);
