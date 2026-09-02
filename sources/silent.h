#pragma once

// Запуск фонового потока Silent Aim (вызывается один раз при старте)
void InitSilentAimThread();

// Остановка потока (необязательно)
void StopSilentAimThread();

// Основная логика, вызываемая внутри потока (можно и извне)
void RunSilentAim();
