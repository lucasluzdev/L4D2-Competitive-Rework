/**
 * L4D2 Weapon Limits + Saferoom T1, v2.1.0-beta (SourcePawn 1.11+)
 * Original concept: CanadaRox and Stabby, L4D Weapon Limits v1.3
 * New implementation: T2 occupancy and start-room T1 additions.
 * Dependency: Left4DHooks (recent version).
 *
 * BETA: Built for server-side testing; does not change existing map spawns.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define VERSION "1.0"
#define T1_TAG_SMG "wl21_smg"
#define T1_TAG_SHOT "wl21_shot"

ConVar g_Limit;
ConVar g_AddMode;
ConVar g_SMG;
ConVar g_Shotgun;
ConVar g_Count;
ConVar g_Hunting;
ConVar g_Css;
ConVar g_Heavy;
ConVar g_EnforceBots;
ConVar g_HumanPriority;
ConVar g_BotReplacement;
ConVar g_FallbackRadius;
ConVar g_Debug;

float g_FirstSurvivorPosition[3];
bool g_HaveStartPosition;
float g_LastNotice[MAXPLAYERS + 1];

public Plugin myinfo = {
    name = "L4D2 Weapon Limits + Saferoom T1",
    author = "Vann09",
    description = "Cap T2 users (including bots) and add T1 to original T2 starting rooms",
    version = VERSION
};

public void OnPluginStart()
{
    char folder[32];
    GetGameFolderName(folder, sizeof(folder));
    if (!StrEqual(folder, "left4dead2"))
        SetFailState("Only Left 4 Dead 2 is supported.");

    g_Limit = CreateConVar("sm_t2_limit", "2", "Max living survivors with T2 (0 disables cap).", FCVAR_NOTIFY, true, 0.0, true, 32.0);
    g_AddMode = CreateConVar("sm_t2_add_mode", "2", "0 off, 1 start T1+T2, 2 also start T2-only.", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_SMG = CreateConVar("sm_t2_smg", "1", "0 Uzi, 1 Silenced SMG, 2 random.", FCVAR_NONE, true, 0.0, true, 2.0);
    g_Shotgun = CreateConVar("sm_t2_shotgun", "1", "0 Pump, 1 Chrome, 2 random.", FCVAR_NONE, true, 0.0, true, 2.0);
    g_Count = CreateConVar("sm_t2_spawn_count", "5", "Pickups available on each added T1 spawn.", FCVAR_NONE, true, 1.0, true, 32.0);
    g_Hunting = CreateConVar("sm_t2_hunting_is_t2", "1", "Include Hunting Rifle as T2.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_Css = CreateConVar("sm_t2_css_snipers_are_t2", "1", "Include Scout/AWP as T2.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_Heavy = CreateConVar("sm_t2_heavy_are_t2", "0", "Include M60/grenade launcher as T2.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_EnforceBots = CreateConVar("sm_t2_enforce_bots", "1", "Audit bot inventories and remove any excess T2.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_HumanPriority = CreateConVar("sm_t2_human_priority", "1", "If cap full with bots, human T2 pickup replaces one bot's T2.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_BotReplacement = CreateConVar("sm_t2_bot_replacement", "1", "Bot replacement: 0 Uzi, 1 silenced SMG, 2 pump, 3 chrome.", FCVAR_NONE, true, 0.0, true, 3.0);
    g_FallbackRadius = CreateConVar("sm_t2_start_radius", "230", "Fallback: spawn <= radius from saved initial survivor position; 0 disables.", FCVAR_NONE, true, 0.0, true, 500.0);
    g_Debug = CreateConVar("sm_t2_debug", "1", "Log room discovery and gun placement.", FCVAR_NONE, true, 0.0, true, 1.0);
    AutoExecConfig(true, "l4d2_weapon_limits_modern");

    HookEvent("round_start", OnRoundStart, EventHookMode_PostNoCopy);
    RegAdminCmd("sm_t2_status", CommandStatus, ADMFLAG_GENERIC, "Show T2 occupants and original saferoom spawn detection.");
    RegAdminCmd("sm_t2_rescan", CommandRescan, ADMFLAG_ROOT, "Rescan the start room and try injecting T1.");
    RegAdminCmd("sm_t2_force_here", CommandForceHere, ADMFLAG_ROOT, "Force one SMG and one T1 shotgun beside your current position (test only). ");

    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i))
            SDKHook(i, SDKHook_WeaponCanUse, OnWeaponCanUse);

    g_HaveStartPosition = false;
    CreateTimer(1.0, TimerCaptureStart, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.5, TimerScan, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, TimerBotAudit, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapStart()
{
    g_HaveStartPosition = false;
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponCanUse, OnWeaponCanUse); // Includes IsFakeClient() bots.
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_WeaponCanUse, OnWeaponCanUse);
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_HaveStartPosition = false;
    CreateTimer(0.3, TimerCaptureStart, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.5, TimerScan, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(4.5, TimerScan, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action TimerCaptureStart(Handle timer)
{
    if (g_HaveStartPosition)
        return Plugin_Stop;

    // Capture a survivor's position early, before the team leaves the room.
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
            continue;
        GetClientAbsOrigin(i, g_FirstSurvivorPosition);
        g_HaveStartPosition = true;
        break;
    }
    return Plugin_Stop;
}

bool IsLivingSurvivor(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client)
        && GetClientTeam(client) == 2 && IsPlayerAlive(client);
}

int CountT2(bool humansOnly = false)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsLivingSurvivor(i) || (humansOnly && IsFakeClient(i)))
            continue;
        if (Tier(GetPlayerWeaponSlot(i, 0)) == 2)
            count++;
    }
    return count;
}

public Action OnWeaponCanUse(int client, int entity)
{
    if (g_Limit.IntValue <= 0 || !IsLivingSurvivor(client) || Tier(entity) != 2)
        return Plugin_Continue;

    // A survivor already holding a T2 is allowed to swap to a different T2.
    if (Tier(GetPlayerWeaponSlot(client, 0)) == 2 || CountT2() < g_Limit.IntValue)
        return Plugin_Continue;

    // When humans take T2, free bot-held slots first.
    if (!IsFakeClient(client) && g_HumanPriority.BoolValue && g_EnforceBots.BoolValue)
    {
        if (DowngradeOneT2Bot())
            return Plugin_Continue;
    }

    if (!IsFakeClient(client) && GetGameTime() > g_LastNotice[client] + 2.0)
    {
        PrintToChat(client, "\x04[Weapon Limits]\x01 Limite de %d usuarios com T2 atingido.", g_Limit.IntValue);
        g_LastNotice[client] = GetGameTime();
    }
    return Plugin_Handled;
}

void BotT1Name(char[] name, int maxlen)
{
    switch (g_BotReplacement.IntValue)
    {
        case 0: strcopy(name, maxlen, "weapon_smg");
        case 2: strcopy(name, maxlen, "weapon_pumpshotgun");
        case 3: strcopy(name, maxlen, "weapon_shotgun_chrome");
        default: strcopy(name, maxlen, "weapon_smg_silenced");
    }
}

bool DowngradeBot(int client)
{
    if (!IsLivingSurvivor(client) || !IsFakeClient(client))
        return false;
    int weapon = GetPlayerWeaponSlot(client, 0);
    if (Tier(weapon) != 2)
        return false;

    if (!RemovePlayerItem(client, weapon))
        return false;
    AcceptEntityInput(weapon, "Kill");
    char t1[40];
    BotT1Name(t1, sizeof(t1));
    int replacement = GivePlayerItem(client, t1);
    if (replacement <= MaxClients || !IsValidEntity(replacement))
        LogError("[WL21] Bot %N lost a T2 but could not receive a T1.", client);
    else if (g_Debug.BoolValue)
        LogMessage("[WL21] Bot %N downgraded to %s.", client, t1);
    return true;
}

bool DowngradeOneT2Bot()
{
    for (int i = MaxClients; i >= 1; i--)
        if (IsLivingSurvivor(i) && IsFakeClient(i) && Tier(GetPlayerWeaponSlot(i, 0)) == 2)
            return DowngradeBot(i);
    return false;
}

public Action TimerBotAudit(Handle timer)
{
    if (!g_EnforceBots.BoolValue || g_Limit.IntValue <= 0)
        return Plugin_Continue;

    int humans = CountT2(true);
    int slotsForBots = g_Limit.IntValue - humans;
    if (slotsForBots < 0)
        slotsForBots = 0;
    int botsKept = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsLivingSurvivor(i) || !IsFakeClient(i) || Tier(GetPlayerWeaponSlot(i, 0)) != 2)
            continue;
        if (botsKept < slotsForBots)
        {
            botsKept++;
            continue;
        }
        DowngradeBot(i);
    }
    return Plugin_Continue;
}

// Tier of a held weapon OR a map spawn; only primary weapons count.
int Tier(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
        return 0;
    char cls[64];
    GetEntityClassname(entity, cls, sizeof(cls));
    if (StrEqual(cls, "weapon_spawn"))
    {
        if (!HasEntProp(entity, Prop_Send, "m_weaponID"))
            return 0;
        int id = GetEntProp(entity, Prop_Send, "m_weaponID");
        switch (id)
        {
            case 2, 3, 7, 8, 33: return 1;
            case 4, 5, 9, 10, 11, 26, 34: return 2;
            case 6: return g_Hunting.BoolValue ? 2 : 0;
            case 35, 36: return g_Css.BoolValue ? 2 : 0;
            case 21, 37: return g_Heavy.BoolValue ? 2 : 0;
        }
        return 0;
    }
    int len = strlen(cls);
    if (len > 6 && StrEqual(cls[len - 6], "_spawn"))
        cls[len - 6] = '\0';
    if (StrEqual(cls, "weapon_smg") || StrEqual(cls, "weapon_smg_silenced") ||
        StrEqual(cls, "weapon_smg_mp5") || StrEqual(cls, "weapon_pumpshotgun") ||
        StrEqual(cls, "weapon_shotgun_chrome"))
        return 1;
    if (StrEqual(cls, "weapon_rifle") || StrEqual(cls, "weapon_rifle_ak47") ||
        StrEqual(cls, "weapon_rifle_desert") || StrEqual(cls, "weapon_rifle_sg552") ||
        StrEqual(cls, "weapon_autoshotgun") || StrEqual(cls, "weapon_shotgun_spas") ||
        StrEqual(cls, "weapon_sniper_military"))
        return 2;
    if (StrEqual(cls, "weapon_hunting_rifle")) return g_Hunting.BoolValue ? 2 : 0;
    if (StrEqual(cls, "weapon_sniper_awp") || StrEqual(cls, "weapon_sniper_scout")) return g_Css.BoolValue ? 2 : 0;
    if (StrEqual(cls, "weapon_grenade_launcher") || StrEqual(cls, "weapon_rifle_m60")) return g_Heavy.BoolValue ? 2 : 0;
    return 0;
}

bool IsSpawn(int ent)
{
    if (ent <= MaxClients || !IsValidEntity(ent))
        return false;
    char cls[64];
    GetEntityClassname(ent, cls, sizeof(cls));
    int len = strlen(cls);
    return StrEqual(cls, "weapon_spawn") ||
        (len > 6 && strncmp(cls, "weapon_", 7) == 0 && StrEqual(cls[len - 6], "_spawn"));
}


// Some maps place single non-spawner weapon entities on racks. Recognize
// unowned primary weapons during the first few seconds, but not held guns.
bool IsOriginalWeaponCandidate(int ent)
{
    if (IsSpawn(ent))
        return true;
    if (ent <= MaxClients || !IsValidEntity(ent))
        return false;
    if (Tier(ent) == 0)
        return false;
    if (HasEntProp(ent, Prop_Send, "m_hOwnerEntity") &&
        GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") > 0)
        return false;
    return true;
}

bool IsTagged(int ent)
{
    if (!HasEntProp(ent, Prop_Data, "m_iName"))
        return false;
    char tag[64];
    GetEntPropString(ent, Prop_Data, "m_iName", tag, sizeof(tag));
    return StrEqual(tag, T1_TAG_SMG) || StrEqual(tag, T1_TAG_SHOT);
}

int FindTagged(const char[] tag)
{
    for (int ent = MaxClients + 1; ent < GetMaxEntities(); ent++)
    {
        if (!IsSpawn(ent) || !HasEntProp(ent, Prop_Data, "m_iName"))
            continue;
        char name[64];
        GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
        if (StrEqual(name, tag))
            return ent;
    }
    return -1;
}

// Check the nav/checkpoint at the spawn's location, and lower samples for
// weapons sitting on elevated tables. A nearby survivor-start fallback is
// constrained by a short radius to reduce false positives on later T2 spawns.
bool InStartRoom(const float pos[3])
{
    float test[3];
    test[0] = pos[0]; test[1] = pos[1]; test[2] = pos[2];
    if (L4D_IsPositionInFirstCheckpoint(test)) return true;
    test[2] -= 32.0;
    if (L4D_IsPositionInFirstCheckpoint(test)) return true;
    test[2] -= 48.0;
    if (L4D_IsPositionInFirstCheckpoint(test)) return true;

    if (g_HaveStartPosition && g_FallbackRadius.FloatValue > 0.0)
    {
        float delta = GetVectorDistance(pos, g_FirstSurvivorPosition);
        if (delta <= g_FallbackRadius.FloatValue &&
            L4D_IsPositionInFirstCheckpoint(g_FirstSurvivorPosition))
            return true;
    }
    return false;
}

void ScanRoom(bool &t1, bool &t2, int &anchor, int &seen, int &inside)
{
    t1 = false; t2 = false; anchor = -1; seen = 0; inside = 0;
    for (int ent = MaxClients + 1; ent < GetMaxEntities(); ent++)
    {
        if (!IsOriginalWeaponCandidate(ent) || IsTagged(ent))
            continue;
        int tier = Tier(ent);
        if (tier == 0)
            continue;
        seen++;
        float pos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
        if (!InStartRoom(pos))
            continue;
        inside++;
        if (tier == 1) t1 = true;
        if (tier == 2) t2 = true;
        if (anchor == -1 || tier == 2)
            anchor = ent;
    }
}

bool NearbySpawn(const float pos[3], float minDistance)
{
    for (int ent = MaxClients + 1; ent < GetMaxEntities(); ent++)
    {
        if (!IsOriginalWeaponCandidate(ent)) continue;
        float existing[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", existing);
        if (GetVectorDistance(pos, existing) < minDistance)
            return true;
    }
    return false;
}

public bool TraceFilterPlacement(int entity, int contentsMask, any data)
{
    // Ignore players and gun entities for hull checking, not walls or props.
    if (entity >= 1 && entity <= MaxClients) return false;
    if (entity > MaxClients && IsValidEntity(entity))
    {
        char cls[64];
        GetEntityClassname(entity, cls, sizeof(cls));
        if (strncmp(cls, "weapon_", 7) == 0) return false;
    }
    return true;
}

// First try nearby spots at nearly the same elevation as the existing rack.
// This fixes the older build which often rejected every point on weapon tables.
bool FindPosition(const float anchor[3], float out[3])
{
    static const float offsets[16][2] = {
        {42.0, 0.0}, {-42.0, 0.0}, {0.0, 42.0}, {0.0, -42.0},
        {55.0, 30.0}, {-55.0, 30.0}, {55.0, -30.0}, {-55.0, -30.0},
        {85.0, 0.0}, {-85.0, 0.0}, {0.0, 85.0}, {0.0, -85.0},
        {75.0, 65.0}, {-75.0, 65.0}, {75.0, -65.0}, {-75.0, -65.0}
    };
    float mins[3] = {-7.0, -7.0, 0.0};
    float maxs[3] = {7.0, 7.0, 14.0};
    for (int i = 0; i < 16; i++)
    {
        float candidate[3];
        candidate[0] = anchor[0] + offsets[i][0];
        candidate[1] = anchor[1] + offsets[i][1];
        candidate[2] = anchor[2] + 9.0;
        if (!InStartRoom(candidate) || NearbySpawn(candidate, 29.0))
            continue;
        Handle trace = TR_TraceHullFilterEx(candidate, candidate, mins, maxs, MASK_SOLID, TraceFilterPlacement);
        bool solid = TR_StartSolid(trace) || TR_AllSolid(trace);
        delete trace;
        if (solid)
            continue;
        out[0] = candidate[0]; out[1] = candidate[1]; out[2] = candidate[2];
        return true;
    }
    return false;
}

int CreateT1Spawn(const char[] cls, const char[] tag, const float pos[3])
{
    int ent = CreateEntityByName(cls);
    if (ent == -1) { LogError("[WL21] Failed creating %s", cls); return -1; }
    char count[12];
    IntToString(g_Count.IntValue, count, sizeof(count));
    DispatchKeyValue(ent, "count", count);
    DispatchKeyValue(ent, "targetname", tag);
    DispatchKeyValue(ent, "spawnflags", "2");
    DispatchKeyValue(ent, "spawn_without_director", "1");
    DispatchKeyValueVector(ent, "origin", pos);
    DispatchSpawn(ent);
    ActivateEntity(ent);
    TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
    if (g_Debug.BoolValue)
        LogMessage("[WL21] Spawned %s at %.0f %.0f %.0f (entity=%d)", cls, pos[0], pos[1], pos[2], ent);
    return ent;
}

bool AddGunsNear(const float pos[3])
{
    int created = 0;
    if (FindTagged(T1_TAG_SMG) == -1)
    {
        float p[3];
        if (FindPosition(pos, p))
        {
            int choice = g_SMG.IntValue == 2 ? GetRandomInt(0, 1) : g_SMG.IntValue;
            if (CreateT1Spawn(choice == 0 ? "weapon_smg_spawn" : "weapon_smg_silenced_spawn", T1_TAG_SMG, p) != -1)
                created++;
        }
        else LogError("[WL21] No free position for SMG near the start-room anchor.");
    }
    if (FindTagged(T1_TAG_SHOT) == -1)
    {
        float p[3];
        if (FindPosition(pos, p))
        {
            int choice = g_Shotgun.IntValue == 2 ? GetRandomInt(0, 1) : g_Shotgun.IntValue;
            if (CreateT1Spawn(choice == 0 ? "weapon_pumpshotgun_spawn" : "weapon_shotgun_chrome_spawn", T1_TAG_SHOT, p) != -1)
                created++;
        }
        else LogError("[WL21] No free position for shotgun near the start-room anchor.");
    }
    return created > 0;
}

public Action TimerScan(Handle timer)
{
    if (g_AddMode.IntValue == 0)
        return Plugin_Stop;
    if (!g_HaveStartPosition)
        TimerCaptureStart(null);
    bool t1, t2;
    int anchor, seen, inside;
    ScanRoom(t1, t2, anchor, seen, inside);
    if (g_Debug.BoolValue)
        LogMessage("[WL21] Saferoom T1=%d T2=%d candidates=%d inside=%d anchor=%d startpos=%d", t1, t2, seen, inside, anchor, g_HaveStartPosition);
    if (!t2 || (g_AddMode.IntValue == 1 && !t1) || anchor == -1)
        return Plugin_Stop;
    float pos[3];
    GetEntPropVector(anchor, Prop_Send, "m_vecOrigin", pos);
    AddGunsNear(pos);
    return Plugin_Stop;
}

public Action CommandStatus(int client, int args)
{
    bool t1, t2;
    int anchor, seen, inside;
    ScanRoom(t1, t2, anchor, seen, inside);
    int humanT2 = CountT2(true);
    int totalT2 = CountT2();
    ReplyToCommand(client, "[WL21] T2: humans=%d bots=%d total=%d/%d | bots-enforced=%d priority=%d", humanT2, totalT2-humanT2, totalT2, g_Limit.IntValue, g_EnforceBots.BoolValue, g_HumanPriority.BoolValue);
    ReplyToCommand(client, "[WL21] Start: original T1=%d T2=%d known-spawns=%d in-room=%d anchor=%d; new SMG=%d shotgun=%d; startpos=%d", t1, t2, seen, inside, anchor, FindTagged(T1_TAG_SMG) != -1, FindTagged(T1_TAG_SHOT) != -1, g_HaveStartPosition);
    return Plugin_Handled;
}

public Action CommandRescan(int client, int args)
{
    TimerScan(null);
    return CommandStatus(client, args);
}

public Action CommandForceHere(int client, int args)
{
    if (client < 1 || !IsLivingSurvivor(client))
    {
        ReplyToCommand(client, "[WL21] Use this command in-game as a living survivor inside the start room.");
        return Plugin_Handled;
    }
    float pos[3];
    GetClientAbsOrigin(client, pos);
    // Manual mode deliberately uses your position as the anchor, independent of T2 detection.
    g_FirstSurvivorPosition[0] = pos[0];
    g_FirstSurvivorPosition[1] = pos[1];
    g_FirstSurvivorPosition[2] = pos[2];
    g_HaveStartPosition = true;
    bool result = AddGunsNear(pos);
    ReplyToCommand(client, "[WL21] Forced T1 near your position: %s. Use sm_t2_status.", result ? "created" : "nothing created (check logs / existing T1)");
    return Plugin_Handled;
}
