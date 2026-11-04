#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public Plugin myinfo =
{
    name = "L4D2 Tickrate Verify",
    author = "Vann09",
    description = "Reads the engine tick interval and measures actual ticks per wall-clock second",
    version = "1.0.0",
    url = ""
};

static const float SAMPLE_SECONDS = 10.0;

float g_WindowStart;
int g_TickStart;
int g_Frames;
float g_LastDuration;
int g_LastTicks;
int g_LastFrames;
bool g_HasSample;

public void OnPluginStart()
{
    RegAdminCmd("sm_tickcheck", Command_TickCheck, ADMFLAG_ROOT,
        "Show configured engine tickrate and observed ticks per second.");
    ResetSampling();
}

public void OnMapStart()
{
    ResetSampling();
}

void ResetSampling()
{
    g_WindowStart = GetEngineTime();
    g_TickStart = GetGameTickCount();
    g_Frames = 0;
    g_LastDuration = 0.0;
    g_LastTicks = 0;
    g_LastFrames = 0;
    g_HasSample = false;
}

public void OnGameFrame()
{
    g_Frames++;
    float now = GetEngineTime();
    float elapsed = now - g_WindowStart;

    if (elapsed < SAMPLE_SECONDS)
        return;

    g_LastDuration = elapsed;
    g_LastTicks = GetGameTickCount() - g_TickStart;
    g_LastFrames = g_Frames;
    g_HasSample = true;

    g_WindowStart = now;
    g_TickStart = GetGameTickCount();
    g_Frames = 0;
}

public Action Command_TickCheck(int client, int args)
{
    float interval = GetTickInterval();
    if (interval <= 0.0)
    {
        ReplyToCommand(client, "[TickCheck] Invalid engine tick interval: %.6f", interval);
        return Plugin_Handled;
    }

    ReplyToCommand(client,
        "[TickCheck] Engine interval: %.6f s | Configured tickrate: %.2f Hz",
        interval, 1.0 / interval);

    if (!g_HasSample)
    {
        ReplyToCommand(client,
            "[TickCheck] No completed sample yet. Stay in-game for 10 seconds and run the command again.");
        return Plugin_Handled;
    }

    ReplyToCommand(client,
        "[TickCheck] Observed: %.2f ticks/s (%d ticks in %.2f s) | OnGameFrame: %.2f frames/s",
        float(g_LastTicks) / g_LastDuration,
        g_LastTicks,
        g_LastDuration,
        float(g_LastFrames) / g_LastDuration);

    return Plugin_Handled;
}
