/*
 * Tank Attack Control - translated chat fix
 * Original authors: vintik, CanadaRox, Jacob, Visor
 * MultiColors integration: OpenAI
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <multicolors>

#define PLUGIN_VERSION "0.7.2"

int g_iQueuedThrow[MAXPLAYERS + 1];
float g_fThrowQueuedAt[MAXPLAYERS + 1];
ConVar g_hBlockPunchRock;
ConVar g_hBlockJumpRock;
ConVar g_hOverhandOnly;

public Plugin myinfo =
{
    name = "Tank Attack Control",
    author = "vintik, CanadaRox, Jacob, Visor; MultiColors integration by OpenAI",
    description = "Tank rock throw controls with translated chat instructions",
    version = PLUGIN_VERSION,
    url = "https://github.com/Attano/L4D2-Competitive-Framework"
};

public void OnPluginStart()
{
    char game[32];
    GetGameFolderName(game, sizeof(game));
    if (!StrEqual(game, "left4dead2", false))
        SetFailState("Plugin supports Left 4 Dead 2 only!");

    LoadTranslations("tank_attack_control.phrases");

    g_hBlockPunchRock = CreateConVar("l4d2_block_punch_rock", "1", "Block punching and throwing a rock at the same time");
    g_hBlockJumpRock = CreateConVar("l4d2_block_jump_rock", "0", "Block jumping and throwing a rock at the same time");
    g_hOverhandOnly = CreateConVar("tank_overhand_only", "0", "Force only two-handed overhand rock throws");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("tank_spawn", Event_TankSpawn);
}

public void OnClientDisconnect(int client)
{
    g_iQueuedThrow[client] = 0;
    g_fThrowQueuedAt[client] = 0.0;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iQueuedThrow[i] = 0;
        g_fThrowQueuedAt[i] = 0.0;
    }
}

// Resolve each phrase in the player's language, then let MultiColors
// process {blue}, {olive}, {default}, etc. No manual color replacements.
void PrintLocalizedColored(int client, const char[] key)
{
    char message[256];
    Format(message, sizeof(message), "%T", key, client);
    CPrintToChat(client, "%s", message);
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int tank = GetClientOfUserId(event.GetInt("userid"));
    if (tank <= 0 || !IsClientInGame(tank) || IsFakeClient(tank))
        return;

    char setting[8];
    bool hideMessage = false;
    if (GetClientInfo(tank, "rs_hidemessage", setting, sizeof(setting)))
        hideMessage = (StringToInt(setting) != 0);

    if (!hideMessage && !g_hOverhandOnly.BoolValue)
    {
        PrintLocalizedColored(tank, "Title");
        PrintLocalizedColored(tank, "Reload");
        PrintLocalizedColored(tank, "Use");
        PrintLocalizedColored(tank, "M2");
    }
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)
        || GetClientTeam(client) != 3
        || GetEntProp(client, Prop_Send, "m_zombieClass") != 8)
        return Plugin_Continue;

    if ((buttons & IN_JUMP) && ShouldCancelJump(client))
        buttons &= ~IN_JUMP;

    if (!g_hOverhandOnly.BoolValue)
    {
        if (buttons & IN_RELOAD)
        {
            g_iQueuedThrow[client] = 3;
            buttons |= IN_ATTACK2;
        }
        else if (buttons & IN_USE)
        {
            g_iQueuedThrow[client] = 2;
            buttons |= IN_ATTACK2;
        }
        else
            g_iQueuedThrow[client] = 1;
    }
    else
        g_iQueuedThrow[client] = 3;

    return Plugin_Continue;
}

public Action L4D_OnCThrowActivate(int ability)
{
    if (ability <= MaxClients || !IsValidEntity(ability))
    {
        LogMessage("Invalid ability_throw index: %d", ability);
        return Plugin_Continue;
    }

    int client = GetEntPropEnt(ability, Prop_Data, "m_hOwnerEntity");
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;

    if ((GetClientButtons(client) & IN_ATTACK) && g_hBlockPunchRock.BoolValue)
        return Plugin_Handled;

    g_fThrowQueuedAt[client] = GetGameTime();
    return Plugin_Continue;
}

public Action L4D2_OnSelectTankAttack(int client, int &sequence)
{
    if (client > 0 && client <= MaxClients && sequence > 48 && g_iQueuedThrow[client] != 0)
    {
        sequence = g_iQueuedThrow[client] + 48;
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

bool ShouldCancelJump(int client)
{
    if (!g_hBlockJumpRock.BoolValue)
        return false;
    return (GetGameTime() - g_fThrowQueuedAt[client]) < 1.5;
}
