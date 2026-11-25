#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <colors>

#define PLUGIN_VERSION "1.2"
#define TEAM_SURVIVOR  2

public Plugin myinfo =
{
	name = "L4D2 Admin Give",
	author = "Vann09",
	description = "Admin menu to give a specific item to a specific survivor (!give).",
	version = PLUGIN_VERSION
};

#define NUM_CATEGORIES 5 // phrases "Cat_0".."Cat_4" in l4d2_admin_give.phrases.txt

// Each entry: category index, give name (also the phrase key), English name (reference only), weapon slot it goes to (-1 = none)
// CSS guns (MP5, SG552, Scout, AWP) are intentionally not offered (confogl_replace_cssweapons 1).
// Melee only works if that melee is loaded on the current map (map's melee weapon list).
static const char ITEMS[][][] = {
	{ "0", "first_aid_kit",          "Medkit",               "3" },
	{ "0", "defibrillator",          "Defibrillator",        "3" },
	{ "0", "pain_pills",             "Pain pills",           "4" },
	{ "0", "adrenaline",             "Adrenaline",           "4" },
	{ "0", "health",                 "Full health",          "-1" },
	{ "1", "pipe_bomb",              "Pipe bomb",            "2" },
	{ "1", "molotov",                "Molotov",              "2" },
	{ "1", "vomitjar",               "Bile jar",             "2" },
	{ "2", "smg",                    "SMG",                  "0" },
	{ "2", "smg_silenced",           "Silenced SMG",         "0" },
	{ "2", "pumpshotgun",            "Pump shotgun",         "0" },
	{ "2", "shotgun_chrome",         "Chrome shotgun",       "0" },
	{ "2", "rifle",                  "M16",                  "0" },
	{ "2", "rifle_ak47",             "AK-47",                "0" },
	{ "2", "rifle_desert",           "SCAR",                 "0" },
	{ "2", "autoshotgun",            "Auto shotgun",         "0" },
	{ "2", "shotgun_spas",           "SPAS shotgun",         "0" },
	{ "2", "hunting_rifle",          "Hunting rifle",        "0" },
	{ "2", "sniper_military",        "Military sniper",      "0" },
	{ "3", "pistol",                 "Pistol",               "1" },
	{ "3", "pistol_magnum",          "Magnum",               "1" },
	{ "3", "katana",                 "Katana",               "1" },
	{ "3", "machete",                "Machete",              "1" },
	{ "3", "fireaxe",                "Fire axe",             "1" },
	{ "3", "crowbar",                "Crowbar",              "1" },
	{ "3", "baseball_bat",           "Baseball bat",         "1" },
	{ "3", "cricket_bat",            "Cricket bat",          "1" },
	{ "3", "frying_pan",             "Frying pan",           "1" },
	{ "3", "electric_guitar",        "Guitar",               "1" },
	{ "3", "tonfa",                  "Nightstick",           "1" },
	{ "3", "golfclub",               "Golf club",            "1" },
	{ "3", "knife",                  "Knife",                "1" },
	{ "4", "ammo",                   "Ammo refill",          "-1" },
	{ "4", "upgradepack_incendiary", "Incendiary ammo pack", "3" },
	{ "4", "upgradepack_explosive",  "Explosive ammo pack",  "3" },
	{ "4", "laser_sight",            "Laser sight",          "-1" }
};

int g_iSelItem[MAXPLAYERS + 1];

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("l4d2_admin_give.phrases");
	CreateConVar("l4d2_admin_give_version", PLUGIN_VERSION, "L4D2 Admin Give version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	RegAdminCmd("sm_give", Cmd_Give, ADMFLAG_GENERIC, "sm_give - opens the item menu | sm_give <item> <target> (e.g. sm_give first_aid_kit Nick, sm_give pain_pills @survivors)");
}

/*
 * ============================
 * Command
 * ============================
 */

public Action Cmd_Give(int client, int args)
{
	if (args >= 2)
	{
		char item[32], targetArg[64];
		GetCmdArg(1, item, sizeof(item));
		GetCmdArg(2, targetArg, sizeof(targetArg));

		int idx = FindItem(item);
		if (idx == -1)
		{
			CReplyToCommand(client, "%T %T", "Tag", client, "Unknown_Item", client, item);
			return Plugin_Handled;
		}

		int targets[MAXPLAYERS];
		char targetName[MAX_TARGET_LENGTH];
		bool tn_is_ml;
		int count = ProcessTargetString(targetArg, client, targets, sizeof(targets),
			COMMAND_FILTER_ALIVE, targetName, sizeof(targetName), tn_is_ml);
		if (count <= 0)
		{
			ReplyToTargetError(client, count);
			return Plugin_Handled;
		}

		int given = 0;
		for (int i = 0; i < count; i++)
		{
			if (GetClientTeam(targets[i]) == TEAM_SURVIVOR && GiveTo(client, targets[i], idx))
				given++;
		}
		if (given == 0)
			CReplyToCommand(client, "%T %T", "Tag", client, "No_Match", client, targetArg);
		return Plugin_Handled;
	}

	if (client <= 0 || !IsClientInGame(client))
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "Usage", client);
		return Plugin_Handled;
	}

	ShowCategoryMenu(client);
	return Plugin_Handled;
}

/*
 * ============================
 * Menus: category -> item -> survivor
 * ============================
 */

void ShowCategoryMenu(int client)
{
	Menu menu = new Menu(Menu_Category);
	menu.SetTitle("%T", "Menu_Category", client);
	char info[4], key[8], label[64];
	for (int i = 0; i < NUM_CATEGORIES; i++)
	{
		IntToString(i, info, sizeof(info));
		FormatEx(key, sizeof(key), "Cat_%d", i);
		FormatEx(label, sizeof(label), "%T", key, client);
		menu.AddItem(info, label);
	}
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Category(Menu menu, MenuAction action, int client, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[4];
		menu.GetItem(param2, info, sizeof(info));
		ShowItemMenu(client, StringToInt(info));
	}
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

void ShowItemMenu(int client, int category)
{
	Menu menu = new Menu(Menu_Item);
	char info[8], key[8], label[64];
	FormatEx(key, sizeof(key), "Cat_%d", category);
	FormatEx(label, sizeof(label), "%T", key, client);
	menu.SetTitle("%T", "Menu_Items", client, label);
	for (int i = 0; i < sizeof(ITEMS); i++)
	{
		if (StringToInt(ITEMS[i][0]) != category)
			continue;
		IntToString(i, info, sizeof(info));
		FormatEx(label, sizeof(label), "%T", ITEMS[i][1], client);
		menu.AddItem(info, label);
	}
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Item(Menu menu, MenuAction action, int client, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, sizeof(info));
		g_iSelItem[client] = StringToInt(info);
		ShowSurvivorMenu(client);
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
		ShowCategoryMenu(client);
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

void ShowSurvivorMenu(int client)
{
	int idx = g_iSelItem[client];
	int slot = StringToInt(ITEMS[idx][3]);

	Menu menu = new Menu(Menu_Survivor);
	char info[16], label[96], held[32], bot[16];
	FormatEx(label, sizeof(label), "%T", ITEMS[idx][1], client);
	menu.SetTitle("%T", "Menu_Target", client, label);
	FormatEx(label, sizeof(label), "%T", "All_Survivors", client);
	menu.AddItem("all", label);
	FormatEx(bot, sizeof(bot), "%T", "Bot", client);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
			continue;

		IntToString(GetClientUserId(i), info, sizeof(info));
		// Show what the survivor already holds in that slot (giving replaces it).
		if (slot >= 0 && GetSlotItem(i, slot, held, sizeof(held)))
			FormatEx(label, sizeof(label), "%N%s [%T: %s]", i, IsFakeClient(i) ? bot : "", "Has", client, held);
		else
			FormatEx(label, sizeof(label), "%N%s", i, IsFakeClient(i) ? bot : "");
		menu.AddItem(info, label);
	}
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Survivor(Menu menu, MenuAction action, int client, int param2)
{
	if (action == MenuAction_Select)
	{
		int idx = g_iSelItem[client];
		char info[16];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "all"))
		{
			for (int i = 1; i <= MaxClients; i++)
			{
				if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
					GiveTo(client, i, idx);
			}
		}
		else
		{
			int target = GetClientOfUserId(StringToInt(info));
			if (target == 0 || !IsClientInGame(target) || GetClientTeam(target) != TEAM_SURVIVOR || !IsPlayerAlive(target))
				CPrintToChat(client, "%T %T", "Tag", client, "Unavailable", client);
			else
				GiveTo(client, target, idx);
		}
		// Reopen the survivor list so the admin can give the same item again.
		ShowSurvivorMenu(client);
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
		ShowItemMenu(client, StringToInt(ITEMS[g_iSelItem[client]][0]));
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

/*
 * ============================
 * Helpers
 * ============================
 */

int FindItem(const char[] item)
{
	for (int i = 0; i < sizeof(ITEMS); i++)
	{
		if (StrEqual(ITEMS[i][1], item, false))
			return i;
	}
	return -1;
}

bool GetSlotItem(int client, int slot, char[] buffer, int maxlen)
{
	int weapon = GetPlayerWeaponSlot(client, slot);
	if (weapon == -1)
		return false;
	GetEntityClassname(weapon, buffer, maxlen);
	ReplaceString(buffer, maxlen, "weapon_", "");
	return true;
}

bool GiveTo(int admin, int target, int idx)
{
	if (StrEqual(ITEMS[idx][1], "laser_sight"))
		CheatCommand(target, "upgrade_add", "laser_sight");
	else
		CheatCommand(target, "give", ITEMS[idx][1]);

	// Each player sees the message (and the item name) in their own language.
	char itemName[64];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		FormatEx(itemName, sizeof(itemName), "%T", ITEMS[idx][1], i);
		CPrintToChat(i, "%T %T", "Tag", i, "Gave", i, admin, itemName, target);
	}
	LogAction(admin, target, "\"%L\" gave \"%s\" to \"%L\"", admin, ITEMS[idx][1], target);
	return true;
}

void CheatCommand(int client, const char[] command, const char[] arg)
{
	int flags = GetCommandFlags(command);
	SetCommandFlags(command, flags & ~FCVAR_CHEAT);
	FakeClientCommand(client, "%s %s", command, arg);
	SetCommandFlags(command, flags);
}
