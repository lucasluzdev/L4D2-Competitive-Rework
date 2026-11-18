/*
 * TankBuster T1 Weapons Menu - per-player chapter quota
 * Based on [L4D] TankBuster Weapons Menu by {7~11} TROLL
 * and Restricted Quota modifications by base64.
 * GPL-3.0 (retain original license terms).
 *
 * 1.1: optional melee weapons (those loaded on the current map, except the riot shield),
 *      unlimited mode (sm_tankbuster_limit 0) and a per-player cooldown.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define VERSION "1.1"
#define NUM_WEAPONS 4
#define MELEE_NAME_LEN 64

public Plugin myinfo =
{
    name = "[L4D2] TankBuster T1 + Anti Exploit",
    author = "Vann09",
    description = "T1 weapons (and optionally melee) with a per-player quota per chapter",
    version = VERSION
};

ConVar g_Enabled;
ConVar g_Limit;
ConVar g_Notify;
ConVar g_EmptyClip;
ConVar g_SmgReserve;
ConVar g_ShotgunReserve;
ConVar g_Melee;
ConVar g_Cooldown;
int g_Used[MAXPLAYERS + 1];
float g_NextUse[MAXPLAYERS + 1];

static const char g_WeaponClass[NUM_WEAPONS][] =
{
    "weapon_pumpshotgun",
    "weapon_shotgun_chrome",
    "weapon_smg",
    "weapon_smg_silenced"
};
static const char g_WeaponName[NUM_WEAPONS][] =
{
    "Pump Shotgun",
    "Chrome Shotgun",
    "Uzi (SMG)",
    "Silenced SMG"
};

// Display names for the stock melee scripts. Anything else (custom melees) shows its script name.
static const char g_MeleeScript[][] =
{
    "baseball_bat", "cricket_bat", "crowbar", "electric_guitar", "fireaxe", "frying_pan",
    "golfclub", "katana", "knife", "machete", "tonfa", "pitchfork", "shovel"
};
static const char g_MeleeLabel[][] =
{
    "Baseball Bat", "Cricket Bat", "Crowbar", "Electric Guitar", "Fire Axe", "Frying Pan",
    "Golf Club", "Katana", "Knife", "Machete", "Tonfa", "Pitchfork", "Shovel"
};

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
        SetFailState("This plugin requires Left 4 Dead 2.");

    g_Enabled = CreateConVar("sm_tankbuster_enabled", "1", "Enable TankBuster T1 menu.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_Limit = CreateConVar("sm_tankbuster_limit", "3", "Maximum weapons per player per map/chapter (0 = unlimited).", FCVAR_NOTIFY, true, 0.0, true, 100.0);
    g_Notify = CreateConVar("sm_tankbuster_notify", "1", "Show weapon and remaining quota after pickup.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_EmptyClip = CreateConVar("sm_tankbuster_empty_clip", "1", "Give T1 weapons with an empty magazine (reserve ammo only, must reload).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_SmgReserve = CreateConVar("sm_tankbuster_smg_reserve", "650", "Reserve ammo granted for SMGs.", FCVAR_NOTIFY, true, 0.0, true, 1000.0);
    g_ShotgunReserve = CreateConVar("sm_tankbuster_shotgun_reserve", "56", "Reserve ammo granted for shotguns.", FCVAR_NOTIFY, true, 0.0, true, 200.0);
    g_Melee = CreateConVar("sm_tankbuster_melee", "0", "Also offer the melee weapons loaded on the current map (riot shield excluded).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_Cooldown = CreateConVar("sm_tankbuster_cooldown", "0", "Seconds a player must wait between TankBuster weapons (0 = no cooldown).", FCVAR_NOTIFY, true, 0.0, true, 600.0);
    RegConsoleCmd("tankbuster", Command_TankBuster, "Open the TankBuster weapon menu.");
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    AutoExecConfig(true, "tankbuster_t1");
}

public void OnMapStart()
{
    ResetAll();
}

public void OnClientDisconnect(int client)
{
    g_Used[client] = 0;
    g_NextUse[client] = 0.0;
}

void ResetAll()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_Used[i] = 0;
        g_NextUse[i] = 0.0;
    }
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // Quota intentionally does NOT reset on round restart, preventing
    // players from obtaining extra weapons by triggering a restart.
    // It resets only on map change or when the client disconnects.
}

bool IsEligible(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client)
        && !IsFakeClient(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client);
}

bool IsUnlimited()
{
    return g_Limit.IntValue <= 0;
}

bool HasQuota(int client)
{
    return IsUnlimited() || g_Used[client] < g_Limit.IntValue;
}

float CooldownLeft(int client)
{
    float left = g_NextUse[client] - GetEngineTime();
    return left > 0.0 ? left : 0.0;
}

public Action Command_TankBuster(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[TankBuster] This command is for players.");
        return Plugin_Handled;
    }
    if (!g_Enabled.BoolValue)
    {
        PrintToChat(client, "\x04[TankBuster]\x01 Menu disabled.");
        return Plugin_Handled;
    }
    if (!IsEligible(client))
    {
        PrintToChat(client, "\x04[TankBuster]\x01 You must be a living survivor.");
        return Plugin_Handled;
    }
    float left = CooldownLeft(client);
    if (left > 0.0)
    {
        PrintToChat(client, "\x04[TankBuster]\x01 Wait %.1f seconds to use it again.", left);
        return Plugin_Handled;
    }
    ShowWeaponMenu(client);
    return Plugin_Handled;
}

void ShowWeaponMenu(int client)
{
    Menu menu = new Menu(MenuHandler);
    char title[128];
    if (IsUnlimited())
    {
        Format(title, sizeof(title), "TankBuster | Unlimited");
    }
    else
    {
        int remaining = g_Limit.IntValue - g_Used[client];
        Format(title, sizeof(title), "TankBuster | Used %d/%d | Remaining %d",
            g_Used[client], g_Limit.IntValue, remaining > 0 ? remaining : 0);
    }
    menu.SetTitle(title);

    int style = HasQuota(client) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED;
    char key[MELEE_NAME_LEN + 2];
    for (int i = 0; i < NUM_WEAPONS; i++)
    {
        Format(key, sizeof(key), "w%d", i);
        menu.AddItem(key, g_WeaponName[i], style);
    }

    if (g_Melee.BoolValue)
    {
        int table = FindStringTable("MeleeWeapons");
        if (table != INVALID_STRING_TABLE)
        {
            char script[MELEE_NAME_LEN], label[MELEE_NAME_LEN];
            int count = GetStringTableNumStrings(table);
            for (int i = 0; i < count; i++)
            {
                ReadStringTable(table, i, script, sizeof(script));
                if (IsRiotShield(script))
                    continue;
                Format(key, sizeof(key), "m%s", script);
                GetMeleeLabel(script, label, sizeof(label));
                menu.AddItem(key, label, style);
            }
        }
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select || !IsEligible(client) || !g_Enabled.BoolValue)
        return 0;

    if (!HasQuota(client))
    {
        PrintToChat(client, "\x04[TankBuster]\x01 Limit reached (%d/%d). Available again next map.",
            g_Used[client], g_Limit.IntValue);
        return 0;
    }

    // Re-checked here: the menu stays open, so it could be used again before the cooldown ends.
    float left = CooldownLeft(client);
    if (left > 0.0)
    {
        PrintToChat(client, "\x04[TankBuster]\x01 Wait %.1f seconds to use it again.", left);
        return 0;
    }

    char key[MELEE_NAME_LEN + 2];
    if (!menu.GetItem(item, key, sizeof(key)))
        return 0;

    char name[MELEE_NAME_LEN];
    if (key[0] == 'w')
    {
        int selection = StringToInt(key[1]);
        if (selection < 0 || selection >= NUM_WEAPONS)
            return 0;
        if (!GiveT1Weapon(client, selection))
            return 0;
        strcopy(name, sizeof(name), g_WeaponName[selection]);
    }
    else if (key[0] == 'm')
    {
        // The cvar or the map may have changed while the menu was open.
        if (!g_Melee.BoolValue || IsRiotShield(key[1]) || !IsMeleeLoaded(key[1]))
        {
            PrintToChat(client, "\x04[TankBuster]\x01 This melee weapon is not available.");
            return 0;
        }
        if (!GiveMelee(client, key[1]))
            return 0;
        GetMeleeLabel(key[1], name, sizeof(name));
    }
    else
    {
        return 0;
    }

    g_Used[client]++;
    g_NextUse[client] = GetEngineTime() + g_Cooldown.FloatValue;

    if (g_Notify.BoolValue)
    {
        if (IsUnlimited())
        {
            PrintToChat(client, "\x04[TankBuster]\x01 Obtained: %s", name);
        }
        else
        {
            int remaining = g_Limit.IntValue - g_Used[client];
            PrintToChat(client, "\x04[TankBuster]\x01 Obtained: %s | Used: %d/%d | Remaining: %d",
                name, g_Used[client], g_Limit.IntValue, remaining);
            if (remaining == 0)
                PrintToChat(client, "\x04[TankBuster]\x01 Next weapon available on the next map.");
        }
    }
    return 0;
}

bool GiveT1Weapon(int client, int selection)
{
    // The engine can refuse GivePlayerItem in unusual situations.
    // Only charge quota if a new entity is successfully created.
    int oldPrimary = GetPlayerWeaponSlot(client, 0);
    if (oldPrimary > MaxClients && IsValidEntity(oldPrimary))
    {
        RemovePlayerItem(client, oldPrimary);
        AcceptEntityInput(oldPrimary, "Kill");
    }

    int newWeapon = GivePlayerItem(client, g_WeaponClass[selection]);
    if (newWeapon <= MaxClients || !IsValidEntity(newWeapon))
    {
        PrintToChat(client, "\x04[TankBuster]\x01 Weapon could not be created. Quota unchanged.");
        LogError("Failed to give %s to client %N", g_WeaponClass[selection], client);
        return false;
    }

    EquipPlayerWeapon(client, newWeapon);

    // Give reserve ammo explicitly: the engine stores primary reserve ammo
    // on the PLAYER, not on the weapon entity, so a given weapon can otherwise
    // end up with 0 reserve rounds. Done in both modes (empty or loaded magazine).
    int ammoType = -1;
    if (HasEntProp(newWeapon, Prop_Data, "m_iPrimaryAmmoType"))
        ammoType = GetEntProp(newWeapon, Prop_Data, "m_iPrimaryAmmoType");
    else if (HasEntProp(newWeapon, Prop_Send, "m_iPrimaryAmmoType"))
        ammoType = GetEntProp(newWeapon, Prop_Send, "m_iPrimaryAmmoType");

    int ammoOffset = FindSendPropInfo("CTerrorPlayer", "m_iAmmo");
    if (ammoOffset <= 0)
        ammoOffset = FindDataMapInfo(client, "m_iAmmo");

    if (ammoType >= 0 && ammoType < 64 && ammoOffset > 0)
    {
        int reserve = (selection < 2) ? g_ShotgunReserve.IntValue : g_SmgReserve.IntValue;
        SetEntData(client, ammoOffset + ammoType * 4, reserve, 4, true);
    }
    else
    {
        LogError("TankBuster: Cannot set reserve ammo (type=%d, offset=%d) for %s", ammoType, ammoOffset, g_WeaponClass[selection]);
        PrintToChat(client, "\x04[TankBuster]\x01 Warning: reserve ammo could not be set; check server logs.");
    }

    // Empty magazine: the player has to reload before shooting.
    if (g_EmptyClip.BoolValue)
    {
        if (HasEntProp(newWeapon, Prop_Send, "m_iClip1"))
            SetEntProp(newWeapon, Prop_Send, "m_iClip1", 0);
        else if (HasEntProp(newWeapon, Prop_Data, "m_iClip1"))
            SetEntProp(newWeapon, Prop_Data, "m_iClip1", 0);
        else
            LogError("TankBuster: m_iClip1 not found on %s", g_WeaponClass[selection]);
    }
    return true;
}

bool GiveMelee(int client, const char[] script)
{
    // "give <script>" is the engine's own way of handing out a melee: it creates the
    // weapon with the right script and drops the current secondary like a normal pickup.
    int flags = GetCommandFlags("give");
    SetCommandFlags("give", flags & ~FCVAR_CHEAT);
    FakeClientCommand(client, "give %s", script);
    SetCommandFlags("give", flags);

    // Only charge quota if the player is now holding that melee.
    int weapon = GetPlayerWeaponSlot(client, 1);
    if (weapon > MaxClients && IsValidEntity(weapon) && HasEntProp(weapon, Prop_Data, "m_strMapSetScriptName"))
    {
        char current[MELEE_NAME_LEN];
        GetEntPropString(weapon, Prop_Data, "m_strMapSetScriptName", current, sizeof(current));
        if (StrEqual(current, script, false))
            return true;
    }

    PrintToChat(client, "\x04[TankBuster]\x01 Weapon could not be created. Quota unchanged.");
    LogError("Failed to give melee %s to client %N", script, client);
    return false;
}

bool IsRiotShield(const char[] script)
{
    return StrContains(script, "riot", false) != -1;
}

bool IsMeleeLoaded(const char[] script)
{
    int table = FindStringTable("MeleeWeapons");
    if (table == INVALID_STRING_TABLE)
        return false;

    char entry[MELEE_NAME_LEN];
    int count = GetStringTableNumStrings(table);
    for (int i = 0; i < count; i++)
    {
        ReadStringTable(table, i, entry, sizeof(entry));
        if (StrEqual(entry, script, false))
            return true;
    }
    return false;
}

void GetMeleeLabel(const char[] script, char[] label, int maxlen)
{
    for (int i = 0; i < sizeof(g_MeleeScript); i++)
    {
        if (StrEqual(script, g_MeleeScript[i], false))
        {
            strcopy(label, maxlen, g_MeleeLabel[i]);
            return;
        }
    }
    strcopy(label, maxlen, script);
}
