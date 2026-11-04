#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>

#define PLUGIN_VERSION "1.6"

public Plugin myinfo =
{
    name = "L4D2 Server Info",
    author = "Vann09",
    description = "Displays competitive server information to players",
    version = PLUGIN_VERSION,
    url = ""
};

bool g_bInfoShown[MAXPLAYERS + 1];

Handle g_hReminderTimer = null;

public void OnPluginStart()
{
    RegConsoleCmd("sm_info", Command_Info);

    HookEvent("round_start", Event_RoundStart);

    LoadTranslations("common.phrases");
    LoadTranslations("l4d2_server_info.phrases");
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bInfoShown[i] = false;
    }

    StartReminderTimer();
}

public void OnMapEnd()
{
    StopReminderTimer();
}

void StartReminderTimer()
{
    StopReminderTimer();

    g_hReminderTimer = CreateTimer(
        300.0,
        Timer_InfoReminder,
        _,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
    );
}

void StopReminderTimer()
{
    if (g_hReminderTimer != null)
    {
        KillTimer(g_hReminderTimer);
        g_hReminderTimer = null;
    }
}

public void OnClientPutInServer(int client)
{
    if (!IsValidClient(client))
        return;

    g_bInfoShown[client] = false;

    CreateTimer(
        10.0,
        Timer_ShowInfoOnJoin,
        GetClientUserId(client),
        TIMER_FLAG_NO_MAPCHANGE
    );
}

public Action Timer_ShowInfoOnJoin(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);

    if (!IsValidClient(client))
        return Plugin_Stop;

    if (g_bInfoShown[client])
        return Plugin_Stop;

    ShowInfoMessage(client);

    return Plugin_Stop;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(
        15.0,
        Timer_ShowInfoToAll,
        _,
        TIMER_FLAG_NO_MAPCHANGE
    );
}

public Action Timer_ShowInfoToAll(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i))
            continue;

        if (g_bInfoShown[i])
            continue;

        ShowInfoMessage(i);
    }

    return Plugin_Stop;
}

public Action Timer_InfoReminder(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i))
            continue;

        CPrintToChat(i, "%T", "Info_Reminder", i);
    }

    return Plugin_Continue;
}

public Action Command_Info(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    ShowInfoMessage(client, false);

    return Plugin_Handled;
}

void ShowInfoMessage(int client, bool markAsShown = true)
{
    if (!IsValidClient(client))
        return;

    CPrintToChat(client, "%T", "Info_AFK", client);
    CPrintToChat(client, "%T", "Info_Team", client);
    CPrintToChat(client, "%T", "Info_TankPass", client);
    CPrintToChat(client, "%T", "Info_TankBuster", client);
    CPrintToChat(client, "%T", "Info_TankFlow", client);
    CPrintToChat(client, "%T", "Info_TankRules", client);

    if (markAsShown)
    {
        g_bInfoShown[client] = true;
    }
}

bool IsValidClient(int client)
{
    return (
        client > 0 &&
        client <= MaxClients &&
        IsClientInGame(client) &&
        !IsFakeClient(client)
    );
}