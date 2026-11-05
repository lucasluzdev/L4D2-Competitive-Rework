#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#undef REQUIRE_PLUGIN
#include <l4d2_saferoom_detect>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION      "3.0"

// Models for removable prop_physics entities
#define MODEL_GASCAN    "models/props_junk/gascan001a.mdl"
#define MODEL_PROPANE   "models/props_junk/propanecanister001a.mdl"
#define MODEL_OXYGEN    "models/props_equipment/oxygentank01.mdl"
#define MODEL_FIREWORKS "models/props_junk/explosive_box001.mdl"

// Credits:
// - Jahze, Sir, A1m` (L4D2 Remove Cans)  - prop_physics removal logic (adapted to support limits) [https://github.com/SirPlease/L4D2-Competitive-Rework/blob/master/addons/sourcemod/scripting/l4d_no_cans.sp]

public Plugin myinfo =
{
    name        = "[L4D2] Limit Item Spawns",
    author      = "Ferks-FK (Touched by EliteBiker and Vann09)",
    description = "Limits the number of item spawns on the map",
    version     = PLUGIN_VERSION,
    url         = "https://forums.alliedmods.net/showthread.php?t=352640"
};

Handle g_hMapTimer;
Handle g_hCansTimerShort;
Handle g_hCansTimerLong;

ConVar g_cvEnable;
ConVar g_cvDebug;
ConVar g_cvMaxMolotov;
ConVar g_cvMaxPipeBomb;
ConVar g_cvMaxPills;
ConVar g_cvMaxAdrenaline;
ConVar g_cvMaxMedkitInside;
ConVar g_cvMaxMedkitOutside;
ConVar g_cvMedkitsFinale;
ConVar g_cvMaxDefibrillator;
ConVar g_cvMaxBileJar;
ConVar g_cvMaxGascan;
ConVar g_cvMaxPropane;
ConVar g_cvMaxOxygen;
ConVar g_cvMaxFireworks;
ConVar g_cvMaxGrenadeLauncher;
ConVar g_cvMaxChainsaw;
ConVar g_cvMaxLaserSight;
ConVar g_cvMaxUpgradeExplosive;
ConVar g_cvMaxUpgradeIncendiary;
ConVar g_cvMenuEnable;
ConVar g_cvMenuShow;

bool   g_bEnabled;
bool   g_bDebug;
bool   g_bLimitedThisRound;
bool   g_bSafeDetectAvailable;
bool   g_bMenuShownThisRound;
bool   g_bItemsReady;
bool   g_bMenuEnabled;

int    g_iMenuShow; // bitmask — see g_sItemLabels for bit mapping (4095 = all)

// Special handling for fallen survivor drops
int g_iCountBeforeDeath[4]; // molotov, pipe_bomb, pain_pills, first_aid_kit

static const char g_sFallenInstances[4][] = {
    "weapon_molotov",
    "weapon_pipe_bomb",
    "weapon_pain_pills",
    "weapon_first_aid_kit"
};

// item labels and their cvars, shown in the panel in this order
static const char g_sItemLabels[12][] = {
    "Molotov",          // bit 0  =   1
    "Pipe Bomb",        // bit 1  =   2
    "Pain Pills",       // bit 2  =   4
    "Adrenaline",       // bit 3  =   8
    "Bile Jar",         // bit 4  =  16
    "Medkit",           // bit 5  =  32
    "Defibrillator",    // bit 6  =  64
    "Grenade Launcher", // bit 7  = 128
    "Chainsaw",         // bit 8  = 256
    "Laser Sight",      // bit 9  = 512
    "Explosive Ammo",   // bit 10 = 1024
    "Incendiary Ammo"   // bit 11 = 2048
};

// Classnames for the items we display in the panel, matching g_sItemLabels order.
static const char g_sItemClassnames[][] = {
    "weapon_molotov_spawn",
    "weapon_pipe_bomb_spawn",
    "weapon_pain_pills_spawn",
    "weapon_adrenaline_spawn",
    "weapon_vomitjar_spawn",
    "weapon_first_aid_kit_spawn",
    "weapon_defibrillator_spawn",
    "weapon_grenade_launcher_spawn",
    "weapon_chainsaw_spawn",
    "upgrade_laser_sight",
    "weapon_upgradepack_explosive_spawn",
    "weapon_upgradepack_incendiary_spawn"
};

public void OnPluginStart()
{
    LoadTranslations("l4d2_limit_items.phrases");

    CreateConVar("l4d2_limit_items_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnable                = CreateConVar("l4d2_limit_items_enable",              "1",  "Enable plugin (1 = On / 0 = Off)", FCVAR_NOTIFY);
    g_cvDebug                 = CreateConVar("l4d2_limit_items_debug",               "0",  "Enable debug mode (1 = On / 0 = Off)", FCVAR_NOTIFY);
    g_cvMenuEnable            = CreateConVar("l4d2_limit_items_menu",                "1",  "0=Disable item limits menu and sm_itemlimits command, 1=Enable.", FCVAR_NOTIFY);
    g_cvMenuShow              = CreateConVar("l4d2_limit_items_menu_show",           "31", "Bitmask of items to show in the menu. 1=Molotov, 2=PipeBomb, 4=Pills, 8=Adrenaline, 16=BileJar, 32=Medkit, 64=Defibrillator, 128=GrenadeLauncher, 256=Chainsaw, 512=LaserSight, 1024=ExplosiveAmmo, 2048=IncendiaryAmmo. 4095=All.", FCVAR_NOTIFY);
    g_cvMaxMolotov            = CreateConVar("l4d2_limit_items_molotov",             "2",  "Max molotov spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxPipeBomb           = CreateConVar("l4d2_limit_items_pipebomb",            "2",  "Max pipe bomb spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxPills              = CreateConVar("l4d2_limit_items_pills",               "4",  "Max pain pills spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxAdrenaline         = CreateConVar("l4d2_limit_items_adrenaline",          "-1", "Max adrenaline spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxMedkitInside       = CreateConVar("l4d2_limit_items_medkit_inside",       "-1", "Max medkits inside the starting saferoom (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMedkitsFinale         = CreateConVar("l4d2_limit_items_medkit_finale", "1", "On finale maps, preserve original medkit spawns (1 = yes, 0 = apply normal limits)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvMaxMedkitOutside      = CreateConVar("l4d2_limit_items_medkit_outside",      "-1", "Max medkits outside the starting saferoom (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxDefibrillator      = CreateConVar("l4d2_limit_items_defibrillator",       "-1", "Max defibrillator spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxBileJar            = CreateConVar("l4d2_limit_items_bilejar",             "-1", "Max bile jar spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxGascan             = CreateConVar("l4d2_limit_items_gascan",              "-1", "Max gascans on the map (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxPropane            = CreateConVar("l4d2_limit_items_propane",             "-1", "Max propane tanks on the map (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxOxygen             = CreateConVar("l4d2_limit_items_oxygen",              "-1", "Max oxygen tanks on the map (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxFireworks          = CreateConVar("l4d2_limit_items_fireworks",           "-1", "Max fireworks on the map (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxGrenadeLauncher    = CreateConVar("l4d2_limit_items_grenade_launcher",    "-1", "Max grenade launcher spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxChainsaw           = CreateConVar("l4d2_limit_items_chainsaw",            "-1", "Max chainsaw spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxLaserSight         = CreateConVar("l4d2_limit_items_laser_sight",         "-1", "Max laser sight spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxUpgradeExplosive   = CreateConVar("l4d2_limit_items_upgrade_explosive",   "-1", "Max explosive ammo upgrade spawns (-1 = unlimited)", FCVAR_NOTIFY);
    g_cvMaxUpgradeIncendiary  = CreateConVar("l4d2_limit_items_upgrade_incendiary",  "-1", "Max incendiary ammo upgrade spawns (-1 = unlimited)", FCVAR_NOTIFY);

    g_cvEnable.AddChangeHook(OnCvarChanged);
    g_cvDebug.AddChangeHook(OnCvarChanged);
    g_cvMenuEnable.AddChangeHook(OnCvarChanged);
    g_cvMenuShow.AddChangeHook(OnCvarChanged);
    g_cvMaxMolotov.AddChangeHook(OnCvarChanged);
    g_cvMaxPipeBomb.AddChangeHook(OnCvarChanged);
    g_cvMaxPills.AddChangeHook(OnCvarChanged);
    g_cvMaxAdrenaline.AddChangeHook(OnCvarChanged);
    g_cvMaxMedkitInside.AddChangeHook(OnCvarChanged);
    g_cvMaxMedkitOutside.AddChangeHook(OnCvarChanged);
    g_cvMedkitsFinale.AddChangeHook(OnCvarChanged);
    g_cvMaxDefibrillator.AddChangeHook(OnCvarChanged);
    g_cvMaxBileJar.AddChangeHook(OnCvarChanged);
    g_cvMaxGascan.AddChangeHook(OnCvarChanged);
    g_cvMaxPropane.AddChangeHook(OnCvarChanged);
    g_cvMaxOxygen.AddChangeHook(OnCvarChanged);
    g_cvMaxFireworks.AddChangeHook(OnCvarChanged);
    g_cvMaxGrenadeLauncher.AddChangeHook(OnCvarChanged);
    g_cvMaxChainsaw.AddChangeHook(OnCvarChanged);
    g_cvMaxLaserSight.AddChangeHook(OnCvarChanged);
    g_cvMaxUpgradeExplosive.AddChangeHook(OnCvarChanged);
    g_cvMaxUpgradeIncendiary.AddChangeHook(OnCvarChanged);

    AutoExecConfig(true, "l4d2_limit_items");

    HookEvent("round_start",            Event_RoundStart,           EventHookMode_PostNoCopy);
    HookEvent("player_spawn",           Event_PlayerSpawn,          EventHookMode_Post);
    HookEvent("player_left_start_area", Event_PlayerLeftStartArea,  EventHookMode_PostNoCopy);

    RegAdminCmd("sm_listitems",   CmdListItems, ADMFLAG_ROOT, "List all active item spawns on the map with coordinates");
    RegConsoleCmd("sm_itemsmenu", CmdShowItemMenu,            "Show the item limits menu.");

    GetCvars();
}

public void OnAllPluginsLoaded()
{
    g_bSafeDetectAvailable = LibraryExists("l4d2_saferoom_detect");
}

public void OnLibraryAdded(const char[] name)
{
    if( StrEqual(name, "l4d2_saferoom_detect") )
        g_bSafeDetectAvailable = true;
}

public void OnLibraryRemoved(const char[] name)
{
    if( StrEqual(name, "l4d2_saferoom_detect") )
        g_bSafeDetectAvailable = false;
}

void GetCvars()
{
    g_bEnabled = g_cvEnable.BoolValue;
    g_bDebug   = g_cvDebug.BoolValue;
    g_bMenuEnabled = g_cvMenuEnable.BoolValue;
    g_iMenuShow    = g_cvMenuShow.IntValue;
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();
}

public void OnPluginEnd()
{
    ClearTimers();
}

public void OnMapEnd()
{
    ClearTimers();
    g_bLimitedThisRound = false;
    g_bItemsReady         = false;
    g_bMenuShownThisRound = false;
}

void ClearTimers()
{
    delete g_hMapTimer;
    delete g_hCansTimerShort;
    delete g_hCansTimerLong;
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_bEnabled || entity <= 0 || entity > 2048)
        return;

    if (StrEqual(classname, "infected"))
        SDKHook(entity, SDKHook_SpawnPost, OnSpawnInfectedPost);
}

void OnSpawnInfectedPost(int entity)
{
    if (isFallenSurvivor(entity))
    {
        if ( g_bDebug )
            LogMessage("[FallenSurvivor] Spawned entity %d, hooking for death detection", entity);

        SDKHook(entity, SDKHook_OnTakeDamageAlivePost, OnFallenSurvivorDamaged);
    }
}

void OnFallenSurvivorDamaged(int entity)
{
    if( GetEntProp(entity, Prop_Data, "m_iHealth") > 0 )
        return;

    if ( g_bDebug )
        LogMessage("[FallenSurvivor] Fallen survivor killed, unhooking...");

    SDKUnhook(entity, SDKHook_OnTakeDamageAlivePost, OnFallenSurvivorDamaged);
    
    for( int i = 0; i < sizeof(g_sFallenInstances); i++ )
    {
        int count = 0;
        int ent   = -1;
        while( (ent = FindEntityByClassname(ent, g_sFallenInstances[i])) != -1 )
            count++;
        g_iCountBeforeDeath[i] = count;
    }

    // Check and remove items on the next frame.
    RequestFrame(Frame_LimitAfterFallenDeath);
}

void Frame_LimitAfterFallenDeath()
{
    int counts[4];

    for( int i = 0; i < sizeof(g_sFallenInstances); i++ )
    {
        int count = 0;
        int ent   = -1;
        while( (ent = FindEntityByClassname(ent, g_sFallenInstances[i])) != -1 )
            count++;
        counts[i] = count;
    }

    if( counts[0] > g_iCountBeforeDeath[0] )
        LimitFallenDrop("weapon_molotov_spawn",       "weapon_molotov",       g_cvMaxMolotov.IntValue,       "Molotov");
    if( counts[1] > g_iCountBeforeDeath[1] )
        LimitFallenDrop("weapon_pipe_bomb_spawn",     "weapon_pipe_bomb",     g_cvMaxPipeBomb.IntValue,      "Pipe Bomb");
    if( counts[2] > g_iCountBeforeDeath[2] )
        LimitFallenDrop("weapon_pain_pills_spawn",    "weapon_pain_pills",    g_cvMaxPills.IntValue,         "Pain Pills");
    if( counts[3] > g_iCountBeforeDeath[3] && !ShouldPreserveFinaleMedkits() )
        LimitFallenDrop("weapon_first_aid_kit_spawn", "weapon_first_aid_kit", g_cvMaxMedkitOutside.IntValue, "Medkit");
}

public void Event_RoundStart(Event hEvent, const char[] name, bool dontBroadcast)
{
    g_bLimitedThisRound = true;
    g_bItemsReady         = false;
    g_bMenuShownThisRound = false;
    ClearTimers();

    g_hMapTimer       = CreateTimer(1.0,  Timer_LimitItems);
    g_hCansTimerShort = CreateTimer(1.0,  Timer_RemoveCans, _, TIMER_FLAG_NO_MAPCHANGE);
    g_hCansTimerLong  = CreateTimer(10.0, Timer_RemoveCans, _, TIMER_FLAG_NO_MAPCHANGE);
}

// Fallback for the first round — round_start may not fire on map start
public void Event_PlayerSpawn(Event hEvent, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(hEvent.GetInt("userid"));

    if( client == 0 || !IsClientInGame(client) || IsFakeClient(client) )
        return;

    // Only trigger for survivors
    // Prevent triggering on infected spawns
    if( GetClientTeam(client) != 2 )
        return;

    if( g_bLimitedThisRound || !g_bEnabled )
        return;

    g_bLimitedThisRound = true;
    g_bItemsReady         = false;
    g_bMenuShownThisRound = false;
    ClearTimers();

    g_hMapTimer       = CreateTimer(1.0, Timer_LimitItems);
    g_hCansTimerShort = CreateTimer(1.0, Timer_RemoveCans, _, TIMER_FLAG_NO_MAPCHANGE);
}

// Fired once per survivor that leaves the starting saferoom.
// We only act on the first one thanks to g_bMenuShownThisRound.
public void Event_PlayerLeftStartArea(Event hEvent, const char[] name, bool dontBroadcast)
{
    if( !g_bMenuEnabled || !g_bItemsReady || g_bMenuShownThisRound )
        return;

    g_bMenuShownThisRound = true;

    for( int i = 1; i <= MaxClients; i++ )
    {
        if( IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == 2 )
            ShowItemMenu(i);
    }
}

Action Timer_LimitItems(Handle timer)
{
    g_hMapTimer = null;

    if( !g_bEnabled )
        return Plugin_Continue;

    LimitSpawns("weapon_molotov_spawn",                  g_cvMaxMolotov.IntValue,       "Molotov");
    LimitSpawns("weapon_pipe_bomb_spawn",                g_cvMaxPipeBomb.IntValue,      "Pipe Bomb");
    LimitSpawns("weapon_pain_pills_spawn",               g_cvMaxPills.IntValue,         "Pain Pills");
    LimitSpawns("weapon_adrenaline_spawn",               g_cvMaxAdrenaline.IntValue,    "Adrenaline");
    LimitSpawns("weapon_defibrillator_spawn",            g_cvMaxDefibrillator.IntValue, "Defibrillator");
    LimitSpawns("weapon_vomitjar_spawn",                 g_cvMaxBileJar.IntValue,       "Bile Jar");

    LimitSpawns("weapon_grenade_launcher_spawn",         g_cvMaxGrenadeLauncher.IntValue,   "Grenade Launcher");
    LimitSpawns("weapon_chainsaw_spawn",                 g_cvMaxChainsaw.IntValue,          "Chainsaw");
    LimitSpawns("upgrade_laser_sight",                   g_cvMaxLaserSight.IntValue,        "Laser Sight");
    LimitSpawns("weapon_upgradepack_explosive_spawn",    g_cvMaxUpgradeExplosive.IntValue,  "Upgrade Explosive");
    LimitSpawns("weapon_upgradepack_incendiary_spawn",   g_cvMaxUpgradeIncendiary.IntValue, "Upgrade Incendiary");

    // Medkit uses its own saferoom-aware logic
    if( !ShouldPreserveFinaleMedkits() )
        LimitMedkitsInStartSaferoom(g_cvMaxMedkitInside.IntValue, g_cvMaxMedkitOutside.IntValue);

    // If there is no long can timer pending (Event_PlayerSpawn path),
    // limiting is fully done — show the menu.
    if( g_hCansTimerLong == null )
        OnLimitingDone();

    return Plugin_Continue;
}

// -------------------------------------------------------
// Removal of prop_physics entities (gascans, propane, oxygen, fireworks)
// -------------------------------------------------------

Action Timer_RemoveCans(Handle timer)
{
    if( timer == g_hCansTimerShort ) g_hCansTimerShort = null;
    if( timer == g_hCansTimerLong )  g_hCansTimerLong  = null;

    if( !g_bEnabled )
        return Plugin_Stop;

    LimitProps(MODEL_GASCAN,    g_cvMaxGascan.IntValue,    "Gascan");
    LimitProps(MODEL_PROPANE,   g_cvMaxPropane.IntValue,   "Propane");
    LimitProps(MODEL_OXYGEN,    g_cvMaxOxygen.IntValue,    "Oxygen");
    LimitProps(MODEL_FIREWORKS, g_cvMaxFireworks.IntValue, "Fireworks");

    // Long timer is the final limiting step — show the menu now.
    if( g_hCansTimerLong == null )
        OnLimitingDone();

    return Plugin_Stop;
}

void LimitProps(const char[] model, int maxAllowed, const char[] label)
{
    if( maxAllowed < 0 )
        return;

    ArrayList hList = new ArrayList();

    int ent = -1;
    while( (ent = FindEntityByClassname(ent, "prop_physics")) != -1 )
    {
        if( !IsValidEdict(ent) )
            continue;

        if( GetEntProp(ent, Prop_Send, "m_isCarryable", 1) < 1 )
            continue;

        char entModel[PLATFORM_MAX_PATH];
        GetEntPropString(ent, Prop_Data, "m_ModelName", entModel, sizeof(entModel));

        if( strcmp(entModel, model, false) == 0 )
            hList.Push(ent);
    }

    int total = hList.Length;

    if( total > maxAllowed )
    {
        // Keep the first maxAllowed, remove the rest
        for( int i = maxAllowed; i < total; i++ )
        {
            int e = hList.Get(i);
            if( IsValidEntity(e) )
                RemoveEntity(e);
        }

        if( g_bDebug )
            LogMessage("[L4D2 Limit Items] %s: found %d, limit %d, removed %d",
                label, total, maxAllowed, total - maxAllowed);
    }

    delete hList;
}

// -------------------------------------------------------
// Generic classname-based limit
// -------------------------------------------------------

void LimitSpawns(const char[] classname, int maxAllowed, const char[] label)
{
    if( maxAllowed < 0 )
        return;

    ArrayList hList = new ArrayList();

    int ent = -1;
    while( (ent = FindEntityByClassname(ent, classname)) != -1 )
        hList.Push(ent);

    int total = hList.Length;

    if( total > maxAllowed )
    {
        for( int i = maxAllowed; i < total; i++ )
        {
            int e = hList.Get(i);
            if( IsValidEntity(e) )
                RemoveEntity(e);
        }

        if( g_bDebug )
            LogMessage("[L4D2 Limit Items] %s: found %d, limit %d, removed %d",
                label, total, maxAllowed, total - maxAllowed);
    }

    delete hList;
}

void LimitFallenDrop(const char[] spawnClass, const char[] instanceClass, int maxAllowed, const char[] label)
{
    if( maxAllowed < 0 )
        return;

    int total = 0;
    int ent   = -1;

    while( (ent = FindEntityByClassname(ent, spawnClass)) != -1 )
    {
        if( !IsInStartSaferoom(ent) )
            total++;
    }

    ArrayList hFloor = new ArrayList();
    ent = -1;
    while( (ent = FindEntityByClassname(ent, instanceClass)) != -1 )
    {
        int owner = GetEntPropEnt(ent, Prop_Data, "m_hOwnerEntity");
        if( owner > 0 && owner <= MaxClients )
        {
            if( !IsInStartSaferoom(owner) )
                total++;
        }
        else
        {
            if( !IsInStartSaferoom(ent) )
            {
                hFloor.Push(ent);
                total++;
            }
        }
    }

    if( total > maxAllowed )
    {
        int toRemove = total - maxAllowed;
        for( int i = hFloor.Length - 1; i >= 0 && toRemove > 0; i-- )
        {
            int e = hFloor.Get(i);
            if( IsValidEntity(e) )
            {
                RemoveEntity(e);
                toRemove--;
            }
        }

        if( g_bDebug )
            LogMessage("[L4D2 Limit Items] [FallenSurvivor] %s: total %d, limit %d, removed %d",
                label, total, maxAllowed, total - maxAllowed);
    }

    delete hFloor;
}

// Finale detection using stock map entities; no extra extension required.
// Some custom finales use unusual entity setups and may need explicit support.
bool ShouldPreserveFinaleMedkits()
{
    if( !g_cvMedkitsFinale.BoolValue )
        return false;

    if( FindEntityByClassname(-1, "trigger_finale") != -1 )
        return true;

    if( FindEntityByClassname(-1, "trigger_finale_dlc3") != -1 )
        return true;

    return false;
}

void LimitMedkitsInStartSaferoom(int maxInside, int maxOutside)
{
    if( maxInside < 0 && maxOutside < 0 )
        return;

    if( !g_bSafeDetectAvailable )
    {
        // Only warn if the user actually configured medkit limits
        if( maxInside >= 0 || maxOutside >= 0 )
            LogError("[L4D2 Limit Items] Medkit limit is configured but l4d2_saferoom_detect is not loaded. Medkit limiting will not work. Install: https://github.com/Tabbernaut/L4D2-Plugins/tree/master/saferoom_detect");
        return;
    }

    ArrayList hInsideEnts = new ArrayList();
    ArrayList hOutsideEnts = new ArrayList();

    int ent = -1;
    while( (ent = FindEntityByClassname(ent, "weapon_first_aid_kit_spawn")) != -1 )
    {
        if( IsInStartSaferoom(ent) )
            hInsideEnts.Push(ent);
        else
            hOutsideEnts.Push(ent);
    }

    int removedInside  = 0;
    int removedOutside = 0;
    int totalInside    = hInsideEnts.Length;
    int totalOutside   = hOutsideEnts.Length;

    // Limit inside kits
    if( maxInside >= 0 && totalInside > maxInside )
    {
        for( int i = maxInside; i < totalInside; i++ )
        {
            int e = hInsideEnts.Get(i);
            if( IsValidEntity(e) )
            {
                RemoveEntity(e);
                removedInside++;
            }
        }
    }

    // Limit outside kits
    if( maxOutside >= 0 && totalOutside > maxOutside )
    {
        for( int i = maxOutside; i < totalOutside; i++ )
        {
            int e = hOutsideEnts.Get(i);
            if( IsValidEntity(e) )
            {
                RemoveEntity(e);
                removedOutside++;
            }
        }
    }

    if( g_bDebug )
    {
        LogMessage("[L4D2 Limit Items] Medkit: inside %d (kept %d, removed %d) limit %d, outside %d (kept %d, removed %d) limit %d",
            totalInside, totalInside - removedInside, removedInside, maxInside,
            totalOutside, totalOutside - removedOutside, removedOutside, maxOutside);
    }

    delete hInsideEnts;
    delete hOutsideEnts;
}

// -------------------------------------------------------
// ITEM MENU
// -------------------------------------------------------

// Called once after all limiting is done. Just marks items as ready.
// The menu is shown when the first survivor leaves the saferoom.
void OnLimitingDone()
{
    g_bItemsReady = true;
}

void ShowItemMenu(int client)
{
    // Medkit combines inside + outside limits into a single total.
    int iMedkitInside  = g_cvMaxMedkitInside.IntValue;
    int iMedkitOutside = g_cvMaxMedkitOutside.IntValue;
    int iMedkitTotal;
    if( iMedkitInside < 0 && iMedkitOutside < 0 )
        iMedkitTotal = -1;
    else if( iMedkitInside < 0 )
        iMedkitTotal = iMedkitOutside;
    else if( iMedkitOutside < 0 )
        iMedkitTotal = iMedkitInside;
    else
        iMedkitTotal = iMedkitInside + iMedkitOutside;

    int cvarLimits[12];
    cvarLimits[0]  = g_cvMaxMolotov.IntValue;
    cvarLimits[1]  = g_cvMaxPipeBomb.IntValue;
    cvarLimits[2]  = g_cvMaxPills.IntValue;
    cvarLimits[3]  = g_cvMaxAdrenaline.IntValue;
    cvarLimits[4]  = g_cvMaxBileJar.IntValue;
    cvarLimits[5]  = iMedkitTotal;
    cvarLimits[6]  = g_cvMaxDefibrillator.IntValue;
    cvarLimits[7]  = g_cvMaxGrenadeLauncher.IntValue;
    cvarLimits[8]  = g_cvMaxChainsaw.IntValue;
    cvarLimits[9]  = g_cvMaxLaserSight.IntValue;
    cvarLimits[10] = g_cvMaxUpgradeExplosive.IntValue;
    cvarLimits[11] = g_cvMaxUpgradeIncendiary.IntValue;

    // Build a list of lines to display before creating the panel,
    // so we can skip it entirely if nothing qualifies.
    char lines[12][64];
    int lineCount = 0;

    for( int i = 0; i < sizeof(g_sItemLabels); i++ )
    {
        if( !(g_iMenuShow & (1 << i)) )
            continue;

        if( cvarLimits[i] < 0 )
            continue;

        int count = CountSpawns(g_sItemClassnames[i]);
        FormatEx(lines[lineCount], 64, "%s: %d", g_sItemLabels[i], count);
        lineCount++;
    }

    if( lineCount == 0 )
        return;

    char sTitle[64];
    char sClose[128];
    FormatEx(sTitle, sizeof(sTitle), "%T", "ItemMenu_Title", client);
    FormatEx(sClose, sizeof(sClose), "%T", "ItemMenu_Close", client);

    Panel panel = new Panel();
    panel.SetTitle(sTitle);
    panel.DrawText(" "); // spacer after title

    for( int i = 0; i < lineCount; i++ )
        panel.DrawText(lines[i]);

    panel.DrawText(" ");
    panel.DrawText(sClose);

    panel.Send(client, MenuHandler_ItemMenu, MENU_TIME_FOREVER);
    delete panel;
}

public int MenuHandler_ItemMenu(Menu menu, MenuAction action, int client, int param2)
{
    // Any key press closes the panel.
    return 0;
}

// -------------------------------------------------------
// sm_listitems — lists active spawns with coordinates
// -------------------------------------------------------

int ListProps(int client, const char[] model, const char[] label)
{
    int count = 0;
    int ent   = -1;

    PrintToConsole(client, "--- %s ---", label);

    while( (ent = FindEntityByClassname(ent, "prop_physics")) != -1 )
    {
        if( !IsValidEdict(ent) )
            continue;

        if( GetEntProp(ent, Prop_Send, "m_isCarryable", 1) < 1 )
            continue;

        char entModel[PLATFORM_MAX_PATH];
        GetEntPropString(ent, Prop_Data, "m_ModelName", entModel, sizeof(entModel));

        if( strcmp(entModel, model, false) != 0 )
            continue;

        float pos[3];
        GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
        count++;
        PrintToConsole(client, "  [world] #%d  %.0f  %.0f  %.0f", count, pos[0], pos[1], pos[2]);
    }

    if( count == 0 )
        PrintToConsole(client, "  (none)");

    return count;
}

Action CmdListItems(int client, int args)
{
    static const char spawns[][] = {
        "weapon_molotov_spawn",
        "weapon_pipe_bomb_spawn",
        "weapon_pain_pills_spawn",
        "weapon_adrenaline_spawn",
        "weapon_first_aid_kit_spawn",
        "weapon_defibrillator_spawn",
        "weapon_vomitjar_spawn",
        "weapon_grenade_launcher_spawn",
        "weapon_chainsaw_spawn",
        "upgrade_laser_sight",
        "weapon_upgradepack_explosive_spawn",
        "weapon_upgradepack_incendiary_spawn"
    };

    static const char instances[][] = {
        "weapon_molotov",
        "weapon_pipe_bomb",
        "weapon_pain_pills",
        "weapon_adrenaline",
        "weapon_first_aid_kit",
        "weapon_defibrillator",
        "weapon_vomitjar",
        "weapon_grenade_launcher",
        "weapon_chainsaw",
        "laser_sight",
        "weapon_upgradepack_explosive",
        "weapon_upgradepack_incendiary"
    };

    static const char labels[][] = {
        "Molotov",
        "Pipe Bomb",
        "Pain Pills",
        "Adrenaline",
        "Medkit",
        "Defibrillator",
        "Bile Jar",
        "Grenade Launcher",
        "Chainsaw",
        "Laser Sight",
        "Upgrade Explosive",
        "Upgrade Incendiary"
    };

    int totalFound = 0;

    PrintToConsole(client, "=== [L4D2 Limit Items] Item Spawns ===");

    for( int t = 0; t < sizeof(labels); t++ )
    {
        int spawnCount    = 0;
        int instanceCount = 0;
        int ent           = -1;
        float pos[3];

        PrintToConsole(client, "--- %s ---", labels[t]);

        while( (ent = FindEntityByClassname(ent, spawns[t])) != -1 )
        {
            GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
            spawnCount++;
            totalFound++;

            // For medkits, show whether they are in the start saferoom
            if( t == 4 )
            {
                char tag[16];
                FormatEx(tag, sizeof(tag), IsInStartSaferoom(ent) ? " [safe]" : "");
                PrintToConsole(client, "  [spawn] #%d  %.0f  %.0f  %.0f%s",
                    spawnCount, pos[0], pos[1], pos[2], tag);
            }
            else
            {
                PrintToConsole(client, "  [spawn] #%d  %.0f  %.0f  %.0f", spawnCount, pos[0], pos[1], pos[2]);
            }
        }

        ent = -1;
        while( (ent = FindEntityByClassname(ent, instances[t])) != -1 )
        {
            GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
            instanceCount++;
            totalFound++;

            if( t == 4 )
            {
                char tag[16];
                FormatEx(tag, sizeof(tag), IsInStartSaferoom(ent) ? " [safe]" : "");
                PrintToConsole(client, "  [world] #%d  %.0f  %.0f  %.0f%s",
                    instanceCount, pos[0], pos[1], pos[2], tag);
            }
            else
            {
                PrintToConsole(client, "  [world] #%d  %.0f  %.0f  %.0f", instanceCount, pos[0], pos[1], pos[2]);
            }
        }

        if( spawnCount == 0 && instanceCount == 0 )
            PrintToConsole(client, "  (none)");
    }

    // Physical props (gascans, propane, oxygen, fireworks)
    totalFound += ListProps(client, MODEL_GASCAN,    "Gascan");
    totalFound += ListProps(client, MODEL_PROPANE,   "Propane");
    totalFound += ListProps(client, MODEL_OXYGEN,    "Oxygen");
    totalFound += ListProps(client, MODEL_FIREWORKS, "Fireworks");

    PrintToConsole(client, "======================================");
    PrintToConsole(client, "Total: %d active items", totalFound);

    if( client != 0 )
        PrintToChat(client, " \x04[L4D2 Limit Items]\x01 List printed to console. (%d items)", totalFound);
    else
        PrintToServer("[L4D2 Limit Items] Total: %d active items", totalFound);

    return Plugin_Handled;
}

public Action CmdShowItemMenu(int client, int args)
{
    if( !client )
        return Plugin_Handled;

    if( !g_bMenuEnabled )
        return Plugin_Handled;

    if( !g_bItemsReady )
    {
        PrintToChat(client, "[L4D2 Limit Items] Item limits not ready yet.");
        return Plugin_Handled;
    }

    ShowItemMenu(client);
    return Plugin_Handled;
}

bool IsInStartSaferoom(int ent)
{
    if( !g_bSafeDetectAvailable )
        return false;

    return SAFEDETECT_IsEntityInStartSaferoom(ent);
}

stock bool isFallenSurvivor(int entity)
{
	if (entity <= 0 || entity > 2048 || !IsValidEntity(entity)) return false;
	char model[128];
    
	GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
	return StrContains(model, "fallen") != -1;
}

// Returns the number of live spawn entities of a given classname.
int CountSpawns(const char[] classname)
{
    int count = 0;
    int ent   = -1;
    while( (ent = FindEntityByClassname(ent, classname)) != -1 )
        count++;
    return count;
}