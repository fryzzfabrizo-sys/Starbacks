#pragma once

// ─── Silent Aim ───────────────────────────────
// Call InitSilentAimThread() once at HUD startup.
// Call RunSilentAim()       every frame inside renderESPWithBuffers.

void RunSilentAim();
void InitSilentAimThread();
