/*
 * TankBuster T1 Weapons Menu - per-player chapter quota
 * Based on [L4D] TankBuster Weapons Menu by {7~11} TROLL
 * and Restricted Quota modifications by base64.
 * GPL-3.0 (retain original license terms).
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define VERSION "1.0"
#define NUM_WEAPONS 4

public Plugin myinfo =
{
    name = "[L4D2] TankBuster T1 + Anti Exploit",
    author = "Vann09",
    description = "Four T1 weapons with a shared per-player quota per chapter",
    version = VERSION
};

ConVar g_Enabled;
ConVar g_Limit;
ConVar g_Notify;
ConVar g_EmptyClip;
ConVar g_SmgReserve;
ConVar g_ShotgunReserve;
int g_Used[MAXPLAYERS + 1];

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

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
        SetFailState("This plugin requires Left 4 Dead 2.");

    g_Enabled = CreateConVar("sm_tankbuster_enabled", "1", "Enable TankBuster T1 menu.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_Limit = CreateConVar("sm_tankbuster_limit", "3", "Maximum T1 weapons per player per map/chapter.", FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_Notify = CreateConVar("sm_tankbuster_notify", "1", "Show weapon and remaining quota after pickup.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_EmptyClip = CreateConVar("sm_tankbuster_empty_clip", "1", "Give TankBuster weapons with an empty magazine and reserve ammo.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_SmgReserve = CreateConVar("sm_tankbuster_smg_reserve", "650", "Reserve ammo granted for SMGs.", FCVAR_NOTIFY, true, 0.0, true, 1000.0);
    g_ShotgunReserve = CreateConVar("sm_tankbuster_shotgun_reserve", "56", "Reserve ammo granted for shotguns.", FCVAR_NOTIFY, true, 0.0, true, 200.0);
    RegConsoleCmd("tankbuster", Command_TankBuster, "Open the T1 weapon menu.");
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
}

void ResetAll()
{
    for (int i = 1; i <= MaxClients; i++)
        g_Used[i] = 0;
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
    ShowWeaponMenu(client);
    return Plugin_Handled;
}

void ShowWeaponMenu(int client)
{
    int remaining = g_Limit.IntValue - g_Used[client];
    Menu menu = new Menu(MenuHandler);
    char title[128];
    Format(title, sizeof(title), "TankBuster T1 | Used %d/%d | Remaining %d",
        g_Used[client], g_Limit.IntValue, remaining > 0 ? remaining : 0);
    menu.SetTitle(title);
    for (int i = 0; i < NUM_WEAPONS; i++)
    {
        char key[8];
        IntToString(i, key, sizeof(key));
        menu.AddItem(key, g_WeaponName[i], remaining > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
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

    if (g_Used[client] >= g_Limit.IntValue)
    {
        PrintToChat(client, "\x04[TankBuster]\x01 Limit reached (%d/%d). Available again next map.",
            g_Used[client], g_Limit.IntValue);
        return 0;
    }

    char key[8];
    if (!menu.GetItem(item, key, sizeof(key)))
        return 0;
    int selection = StringToInt(key);
    if (selection < 0 || selection >= NUM_WEAPONS)
        return 0;

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
        return 0;
    }

    EquipPlayerWeapon(client, newWeapon);
    // Give reserve ammo explicitly: the engine stores primary reserve ammo
    // on the PLAYER, not on the weapon entity. Emptying m_iClip1 alone
    // can leave the weapon with 0 reserve rounds.
    if (g_EmptyClip.BoolValue)
    {
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

        if (HasEntProp(newWeapon, Prop_Send, "m_iClip1"))
            SetEntProp(newWeapon, Prop_Send, "m_iClip1", 0);
        else if (HasEntProp(newWeapon, Prop_Data, "m_iClip1"))
            SetEntProp(newWeapon, Prop_Data, "m_iClip1", 0);
        else
            LogError("TankBuster: m_iClip1 not found on %s", g_WeaponClass[selection]);
    }
    g_Used[client]++;
    if (g_Notify.BoolValue)
    {
        int left = g_Limit.IntValue - g_Used[client];
        PrintToChat(client, "\x04[TankBuster]\x01 Obtained: %s | Used: %d/%d | Remaining: %d",
            g_WeaponName[selection], g_Used[client], g_Limit.IntValue, left);
        if (left == 0)
            PrintToChat(client, "\x04[TankBuster]\x01 Next weapon available on the next map.");
    }
    return 0;
}
