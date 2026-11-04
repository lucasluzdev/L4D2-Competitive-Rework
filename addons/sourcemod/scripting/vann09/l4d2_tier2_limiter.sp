#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define VERSION "1.0.0"

public Plugin myinfo =
{
    name = "L4D2 Tier 2 Limiter + Ammo",
    author = "Vann09",
    description = "Limits T2 holders, adds ammo piles near weapon spawns, refills T1 on denied T2 pickup",
    version = VERSION
};

ConVar g_Enabled, g_Limit, g_Notify, g_Debug;
ConVar g_SpawnAmmo, g_AmmoRadius, g_Refill, g_Cooldown, g_AmmoNotify;
ConVar g_SmgReserve, g_ShotgunReserve;
float g_LastNotice[MAXPLAYERS + 1], g_LastRefill[MAXPLAYERS + 1];
Handle g_ScanTimer = null;
int g_PilesCreated;

public void OnPluginStart()
{
    char game[32];
    GetGameFolderName(game, sizeof(game));
    if (!StrEqual(game, "left4dead2", false))
        SetFailState("Requires Left 4 Dead 2");

    g_Enabled = CreateConVar("sm_t2_enabled", "1", "Enable T2 pickup limiter", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_Limit = CreateConVar("sm_t2_limit", "2", "Maximum simultaneous T2 survivors", FCVAR_NOTIFY, true, 0.0, true, 32.0);
    g_Notify = CreateConVar("sm_t2_notify", "1", "Notify when T2 pickup is blocked", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_Debug = CreateConVar("sm_t2_debug", "0", "Enable diagnostics", FCVAR_NONE, true, 0.0, true, 1.0);
    g_SpawnAmmo = CreateConVar("sm_t2_spawn_ammo_piles", "1", "Spawn ammo piles near weapon spawn entities", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_AmmoRadius = CreateConVar("sm_t2_ammo_spawn_radius", "100", "Do not create pile when another is this close (units)", FCVAR_NOTIFY, true, 24.0, true, 500.0);
    g_Refill = CreateConVar("sm_t2_blocked_weapon_ammo", "1", "Blocked T2 pickup refills T1 reserve ammo", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_Cooldown = CreateConVar("sm_t2_ammo_cooldown", "2.0", "Minimum seconds between T1 ammo refill attempts", FCVAR_NOTIFY, true, 0.1, true, 60.0);
    g_AmmoNotify = CreateConVar("sm_t2_ammo_notify", "1", "Notify player when blocked T2 refills ammo", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_SmgReserve = CreateConVar("sm_t2_smg_reserve", "650", "Target SMG reserve ammo when refilled", FCVAR_NOTIFY, true, 0.0, true, 1000.0);
    g_ShotgunReserve = CreateConVar("sm_t2_shotgun_reserve", "56", "Target pump/chrome reserve ammo when refilled", FCVAR_NOTIFY, true, 0.0, true, 200.0);

    RegConsoleCmd("sm_t2", Command_Status);
    RegConsoleCmd("sm_t2_status", Command_Status);
    RegAdminCmd("sm_t2_ammo_scan", Command_Scan, ADMFLAG_GENERIC);
    RegAdminCmd("sm_t2_ammo_test", Command_AmmoTest, ADMFLAG_GENERIC);
    AutoExecConfig(true, "l4d2_tier2_limiter");

    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i)) SDKHook(i, SDKHook_WeaponCanUse, OnWeaponCanUse);
}

public void OnMapStart()
{
    g_PilesCreated = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_LastNotice[i] = -1000.0;
        g_LastRefill[i] = -1000.0;
    }
    // Repeated scan handles Director-created weapon spawns; nearby-pile check avoids duplicates.
    g_ScanTimer = CreateTimer(5.0, Timer_Scan, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd() { g_ScanTimer = null; }
public void OnClientPutInServer(int client)
{
    g_LastNotice[client] = -1000.0;
    g_LastRefill[client] = -1000.0;
    SDKHook(client, SDKHook_WeaponCanUse, OnWeaponCanUse);
}
public void OnClientDisconnect(int client)
{
    g_LastNotice[client] = -1000.0;
    g_LastRefill[client] = -1000.0;
}

bool IsT2(const char[] name)
{
    return StrEqual(name, "weapon_rifle") || StrEqual(name, "weapon_rifle_ak47")
        || StrEqual(name, "weapon_rifle_desert") || StrEqual(name, "weapon_rifle_sg552")
        || StrEqual(name, "weapon_autoshotgun") || StrEqual(name, "weapon_shotgun_spas")
        || StrEqual(name, "weapon_hunting_rifle") || StrEqual(name, "weapon_sniper_military")
        || StrEqual(name, "weapon_sniper_awp") || StrEqual(name, "weapon_sniper_scout");
}

bool IsT2Entity(int ent)
{
    if (ent <= MaxClients || !IsValidEntity(ent)) return false;
    char name[80];
    GetEntityClassname(ent, name, sizeof(name));
    return IsT2(name);
}

bool HoldingT2(int client)
{
    return IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client)
        && IsT2Entity(GetPlayerWeaponSlot(client, 0));
}

int CountT2()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++) if (HoldingT2(i)) n++;
    return n;
}

// The player's reserve ammo is stored in m_iAmmo indexed by the weapon's ammo type.
// Only the four T1 primary weapons are eligible, so other weapon ammo is not changed.
bool RefillT1Reserve(int client, bool diagnostic = false)
{
    int weapon = GetPlayerWeaponSlot(client, 0);
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        if (diagnostic) ReplyToCommand(client, "[T2 Ammo] No valid primary weapon.");
        return false;
    }

    char name[80];
    GetEntityClassname(weapon, name, sizeof(name));
    int target;
    if (StrEqual(name, "weapon_smg") || StrEqual(name, "weapon_smg_silenced"))
        target = g_SmgReserve.IntValue;
    else if (StrEqual(name, "weapon_pumpshotgun") || StrEqual(name, "weapon_shotgun_chrome"))
        target = g_ShotgunReserve.IntValue;
    else
    {
        if (diagnostic) ReplyToCommand(client, "[T2 Ammo] Not an eligible T1: %s", name);
        return false;
    }

    // L4D2 stores reserve ammo as an indexed sendprop array on the PLAYER.
    // The index is the equipped weapon's primary ammo type.
    PropType type = Prop_Send;
    if (!HasEntProp(weapon, type, "m_iPrimaryAmmoType"))
    {
        type = Prop_Data;
        if (!HasEntProp(weapon, type, "m_iPrimaryAmmoType"))
        {
            LogError("[T2 Ammo] Weapon %s has no m_iPrimaryAmmoType", name);
            return false;
        }
    }
    int ammoType = GetEntProp(weapon, type, "m_iPrimaryAmmoType");
    if (!HasEntProp(client, Prop_Send, "m_iAmmo"))
    {
        LogError("[T2 Ammo] Player missing m_iAmmo sendprop");
        return false;
    }
    int count = GetEntPropArraySize(client, Prop_Send, "m_iAmmo");
    if (ammoType < 0 || ammoType >= count)
    {
        LogError("[T2 Ammo] Invalid ammoType=%d, array size=%d, weapon=%s", ammoType, count, name);
        return false;
    }

    int existing = GetEntProp(client, Prop_Send, "m_iAmmo", 4, ammoType);
    if (diagnostic || g_Debug.BoolValue)
        PrintToServer("[T2 Ammo] client=%N weapon=%s ammoType=%d reserve=%d target=%d", client, name, ammoType, existing, target);
    if (existing >= target)
    {
        if (diagnostic) ReplyToCommand(client, "[T2 Ammo] Already full: %d/%d", existing, target);
        return false;
    }

    SetEntProp(client, Prop_Send, "m_iAmmo", target, 4, ammoType);
    int verified = GetEntProp(client, Prop_Send, "m_iAmmo", 4, ammoType);
    if (diagnostic) ReplyToCommand(client, "[T2 Ammo] Reserve: %d -> %d (target %d)", existing, verified, target);
    return verified > existing;
}

public Action Command_AmmoTest(int client, int args)
{
    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "[T2 Ammo] Use this command as a living survivor in-game.");
        return Plugin_Handled;
    }
    RefillT1Reserve(client, true);
    return Plugin_Handled;
}

public Action OnWeaponCanUse(int client, int weapon)
{
    if (!g_Enabled.BoolValue || !IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
        return Plugin_Continue;
    if (!IsT2Entity(weapon) || HoldingT2(client)) return Plugin_Continue;

    int current = CountT2(), limit = g_Limit.IntValue;
    if (current < limit) return Plugin_Continue;

    if (!IsFakeClient(client))
    {
        float now = GetGameTime();
        bool refilled = false;
        if (g_Refill.BoolValue && now - g_LastRefill[client] >= g_Cooldown.FloatValue)
        {
            // Mark attempt even when already full, to prevent repeated work.
            g_LastRefill[client] = now;
            refilled = RefillT1Reserve(client);
        }
        if (refilled && g_AmmoNotify.BoolValue)
            PrintToChat(client, "\x04[T2 Limiter]\x01 T2 bloqueada (%d/%d). Municao T1 reabastecida!", current, limit);
        else if (g_Notify.BoolValue && now - g_LastNotice[client] >= 2.0)
        {
            PrintToChat(client, "\x04[T2 Limiter]\x01 Limite T2 atingido (%d/%d).", current, limit);
            g_LastNotice[client] = now;
        }
    }
    if (g_Debug.BoolValue) LogMessage("T2 denied: client=%N, holders=%d, limit=%d", client, current, limit);
    return Plugin_Handled;
}

bool IsWeaponSpawn(const char[] name)
{
    if (StrEqual(name, "weapon_spawn")) return true;
    if (StrEqual(name, "weapon_ammo_spawn")) return false;
    if (strncmp(name, "weapon_", 7) != 0) return false;
    int len = strlen(name);
    if (len < 12 || !StrEqual(name[len - 6], "_spawn")) return false;
    // Exclude non-primary weapon spawns and supplies.
    return StrContains(name, "rifle") != -1 || StrContains(name, "shotgun") != -1
        || StrContains(name, "smg") != -1 || StrContains(name, "sniper") != -1;
}

bool GetOrigin(int ent, float pos[3])
{
    if (HasEntProp(ent, Prop_Send, "m_vecOrigin"))
    {
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
        return true;
    }
    if (HasEntProp(ent, Prop_Data, "m_vecAbsOrigin"))
    {
        GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
        return true;
    }
    return false;
}

bool NearbyAmmo(const float pos[3])
{
    int ent = -1;
    float other[3];
    while ((ent = FindEntityByClassname(ent, "weapon_ammo_spawn")) != -1)
    {
        if (GetOrigin(ent, other) && GetVectorDistance(pos, other) <= g_AmmoRadius.FloatValue)
            return true;
    }
    return false;
}

bool TraceFilterWorldOnly(int ent, int mask, any data)
{
    // Ignore players and entities; collide with world geometry only.
    return ent == 0;
}

bool FindPilePosition(const float origin[3], float out[3])
{
    static const float offsets[9][3] = {
        {32.0,0.0,0.0}, {-32.0,0.0,0.0}, {0.0,32.0,0.0}, {0.0,-32.0,0.0},
        {48.0,0.0,0.0}, {-48.0,0.0,0.0}, {0.0,48.0,0.0}, {0.0,-48.0,0.0},
        {0.0,0.0,0.0}
    };
    float mins[3] = {-10.0, -10.0, 0.0};
    float maxs[3] = {10.0, 10.0, 20.0};
    for (int i = 0; i < sizeof(offsets); i++)
    {
        for (int j = 0; j < 3; j++) out[j] = origin[j] + offsets[i][j];
        TR_TraceHullFilter(out, out, mins, maxs, MASK_SOLID, TraceFilterWorldOnly);
        if (!TR_DidHit()) return true;
    }
    return false;
}

int ScanWeaponSpawns()
{
    if (!g_SpawnAmmo.BoolValue) return 0;
    int added = 0;
    char name[80];
    float origin[3], location[3];
    int max = GetMaxEntities();
    for (int ent = MaxClients + 1; ent < max; ent++)
    {
        if (!IsValidEntity(ent)) continue;
        GetEntityClassname(ent, name, sizeof(name));
        if (!IsWeaponSpawn(name) || !GetOrigin(ent, origin) || NearbyAmmo(origin)) continue;
        if (!FindPilePosition(origin, location)) continue;
        int pile = CreateEntityByName("weapon_ammo_spawn");
        if (pile == -1) continue;
        DispatchKeyValue(pile, "spawnflags", "0");
        TeleportEntity(pile, location, NULL_VECTOR, NULL_VECTOR);
        if (!DispatchSpawn(pile))
        {
            RemoveEntity(pile);
            continue;
        }
        ActivateEntity(pile);
        added++;
        g_PilesCreated++;
    }
    if (g_Debug.BoolValue && added > 0) LogMessage("Created %d ammo piles (map total %d)", added, g_PilesCreated);
    return added;
}

public Action Timer_Scan(Handle timer)
{
    ScanWeaponSpawns();
    return Plugin_Continue;
}

public Action Command_Scan(int client, int args)
{
    int added = ScanWeaponSpawns();
    ReplyToCommand(client, "[T2 Limiter] Added %d piles now; total this map: %d", added, g_PilesCreated);
    return Plugin_Handled;
}

public Action Command_Status(int client, int args)
{
    int humans = 0, bots = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!HoldingT2(i)) continue;
        if (IsFakeClient(i)) bots++; else humans++;
    }
    ReplyToCommand(client, "[T2 Limiter] T2: %d/%d | Humans: %d | Bots: %d | Ammo piles created: %d", humans + bots, g_Limit.IntValue, humans, bots, g_PilesCreated);
    return Plugin_Handled;
}
