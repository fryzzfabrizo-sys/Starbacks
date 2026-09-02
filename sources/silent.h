#pragma once

void InitSilentAimThread();   // запустить поток один раз
void RunSilentAim();          // вызывается каждый кадр, обновляет данные для потока
void ResetSilentAim();        // заглушка (опционально)
