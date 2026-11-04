#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

public Plugin myinfo =
{
    name = "L4D2 Saferoom T1 + Preserve T2",
    author = "Vann09",
    description = "Adds T1 next to starting saferoom T2 without removing original T2 spawns",
    version = "1.0.0"
};

ConVar g_Enable, g_Count, g_Debug;
bool g_Done;
int g_Added[2];
static const char T1_CLASS[][] = {
    "weapon_smg_silenced_spawn",
    "weapon_shotgun_chrome_spawn"
};

public void OnPluginStart()
{
    g_Enable = CreateConVar("sm_sr_t1_enabled", "1", "Enable saferoom T1 additions", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_Count = CreateConVar("sm_sr_t1_count", "5", "Number of pickups per added T1 spawn", FCVAR_NOTIFY, true, 1.0, true, 32.0);
    g_Debug = CreateConVar("sm_sr_t1_debug", "0", "Enable detailed logging", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    AutoExecConfig(true, "l4d2_saferoom_t1_preserve");
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    RegAdminCmd("sm_sr_t1_status", Command_Status, ADMFLAG_GENERIC);
    RegAdminCmd("sm_sr_t1_rescan", Command_Rescan, ADMFLAG_ROOT);
}

public void OnMapStart()
{
    g_Done = false;
    g_Added[0] = -1;
    g_Added[1] = -1;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(2.0, Timer_Scan, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Scan(Handle timer)
{
    ScanAndAdd();
    return Plugin_Stop;
}

public Action Command_Status(int client, int args)
{
    ReplyToCommand(client, "[SR T1] processed=%d, SMG=%d, Shotgun=%d", g_Done, IsAddedValid(0), IsAddedValid(1));
    return Plugin_Handled;
}

public Action Command_Rescan(int client, int args)
{
    // Existing additions are preserved; no duplicates are created.
    g_Done = false;
    ScanAndAdd();
    ReplyToCommand(client, "[SR T1] Rescan complete. Check server logs.");
    return Plugin_Handled;
}

bool IsAddedValid(int slot)
{
    return g_Added[slot] > MaxClients && IsValidEntity(g_Added[slot]);
}

bool IsT1(const char[] classname, int ent)
{
    if (StrEqual(classname, "weapon_smg_spawn") ||
        StrEqual(classname, "weapon_smg_silenced_spawn") ||
        StrEqual(classname, "weapon_smg_mp5_spawn") ||
        StrEqual(classname, "weapon_pumpshotgun_spawn") ||
        StrEqual(classname, "weapon_shotgun_chrome_spawn"))
        return true;

    if (StrEqual(classname, "weapon_spawn") && HasEntProp(ent, Prop_Send, "m_weaponID"))
    {
        int id = GetEntProp(ent, Prop_Send, "m_weaponID");
        return id == 2 || id == 3 || id == 7 || id == 8 || id == 33;
    }
    return false;
}

bool IsT2(const char[] classname, int ent)
{
    if (StrEqual(classname, "weapon_rifle_spawn") ||
        StrEqual(classname, "weapon_rifle_ak47_spawn") ||
        StrEqual(classname, "weapon_rifle_desert_spawn") ||
        StrEqual(classname, "weapon_rifle_sg552_spawn") ||
        StrEqual(classname, "weapon_autoshotgun_spawn") ||
        StrEqual(classname, "weapon_shotgun_spas_spawn") ||
        StrEqual(classname, "weapon_hunting_rifle_spawn") ||
        StrEqual(classname, "weapon_sniper_military_spawn") ||
        StrEqual(classname, "weapon_sniper_awp_spawn") ||
        StrEqual(classname, "weapon_sniper_scout_spawn"))
        return true;

    if (StrEqual(classname, "weapon_spawn") && HasEntProp(ent, Prop_Send, "m_weaponID"))
    {
        int id = GetEntProp(ent, Prop_Send, "m_weaponID");
        switch (id)
        {
            case 4, 5, 6, 9, 10, 11, 26, 34, 35, 36: return true;
        }
    }
    return false;
}

bool IsCheckpointWeapon(int ent, float pos[3])
{
    if (!IsValidEntity(ent) || !HasEntProp(ent, Prop_Send, "m_vecOrigin"))
        return false;
    GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
    return L4D_IsPositionInFirstCheckpoint(pos);
}

void ScanAndAdd()
{
    if (!g_Enable.BoolValue || g_Done)
        return;

    int anchors[128];
    int count = 0;
    bool hasT1 = false;
    char classname[80];
    float pos[3];

    int maxEnt = GetMaxEntities();
    for (int ent = MaxClients + 1; ent < maxEnt; ent++)
    {
        if (!IsValidEntity(ent))
            continue;
        GetEntityClassname(ent, classname, sizeof(classname));
        if (!IsT1(classname, ent) && !IsT2(classname, ent))
            continue;
        if (!IsCheckpointWeapon(ent, pos))
            continue;
        if (IsT1(classname, ent))
            hasT1 = true;
        else if (count < sizeof(anchors))
            anchors[count++] = EntIndexToEntRef(ent);
    }

    if (hasT1 || count == 0)
    {
        g_Done = true;
        LogMessage("[SR T1] No changes: T1 present=%d, T2 anchors=%d", hasT1, count);
        return;
    }

    // Keep every original T2 spawn intact. New T1 spawns use safe adjacent
    // candidate positions; if none is found, no new spawn is created.
    int created = 0;
    for (int slot = 0; slot < 2; slot++)
    {
        if (IsAddedValid(slot))
        {
            created++;
            continue;
        }
        int anchor = EntRefToEntIndex(anchors[slot % count]);
        if (anchor <= MaxClients || !IsValidEntity(anchor))
            continue;
        float origin[3], angles[3], candidate[3];
        GetEntPropVector(anchor, Prop_Send, "m_vecOrigin", origin);
        GetEntPropVector(anchor, Prop_Send, "m_angRotation", angles);
        if (!FindNearbyPosition(origin, slot, candidate))
        {
            LogError("[SR T1] No valid position near T2 anchor for %s", T1_CLASS[slot]);
            continue;
        }
        int ent = CreateEntityByName(T1_CLASS[slot]);
        if (ent == -1)
            continue;
        char amount[12];
        IntToString(g_Count.IntValue, amount, sizeof(amount));
        DispatchKeyValue(ent, "count", amount);
        DispatchKeyValue(ent, "spawnflags", "2");
        TeleportEntity(ent, candidate, angles, NULL_VECTOR);
        if (!DispatchSpawn(ent))
        {
            RemoveEntity(ent);
            continue;
        }
        ActivateEntity(ent);
        g_Added[slot] = ent;
        created++;
        LogMessage("[SR T1] Added %s near original T2 (entity %d)", T1_CLASS[slot], anchor);
    }
    g_Done = (created == 2);
    LogMessage("[SR T1] Finished: %d/2 added, original T2 unchanged", created);
}

bool FindNearbyPosition(const float origin[3], int slot, float result[3])
{
    static const float offsets[12][3] = {
        {45.0,0.0,0.0}, {-45.0,0.0,0.0},
        {0.0,45.0,0.0}, {0.0,-45.0,0.0},
        {65.0,25.0,0.0}, {-65.0,25.0,0.0},
        {25.0,65.0,0.0}, {25.0,-65.0,0.0},
        {80.0,0.0,0.0}, {-80.0,0.0,0.0},
        {0.0,80.0,0.0}, {0.0,-80.0,0.0}
    };
    for (int i = 0; i < 12; i++)
    {
        int j = (i + slot * 3) % 12;
        for (int k = 0; k < 3; k++)
            result[k] = origin[k] + offsets[j][k];
        if (!L4D_IsPositionInFirstCheckpoint(result))
            continue;
        TR_TraceHullFilter(result, result, {-12.0,-12.0,0.0}, {12.0,12.0,24.0}, MASK_SOLID, TraceFilter_IgnorePlayers);
        if (!TR_DidHit())
            return true;
    }
    return false;
}

public bool TraceFilter_IgnorePlayers(int entity, int contentsMask)
{
    return entity < 1 || entity > MaxClients;
}
