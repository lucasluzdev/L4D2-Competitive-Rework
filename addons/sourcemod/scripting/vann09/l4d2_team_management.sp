#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "2.0"
#define PLUGIN_NAME    "Team management"

/*
 * 2.0 - Works on top of competitive-rework's playermanagement.smx:
 *   - !spec / !spectate / !s are no longer registered here (playermanagement owns them).
 *     Registering them twice made BOTH handlers run, so the raw team change here
 *     bypassed playermanagement's checks (e.g. a capped survivor could !spec out of a cap).
 *   - !afk / !away / !idle / !spectators / !joinspectators / !jointeam1 are forwarded
 *     to playermanagement's sm_spectate, so they get the same checks.
 *   - The admin !mts menu moves players through sm_swapto (playermanagement).
 *   - Falls back to a plain team change only if playermanagement is not loaded.
 */

public Plugin myinfo =
{
	name = PLUGIN_NAME,
	author = "Vann09",
	description = "Extra team commands (afk aliases, join survivors/infected, admin move-to-spec menu) on top of playermanagement.",
	version = PLUGIN_VERSION
};

public void OnPluginStart()
{
	CreateConVar("afk_spectate_commands_version", PLUGIN_VERSION, "Team management plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	// Spectator aliases -> playermanagement's sm_spectate
	RegConsoleCmd("sm_afk", Cmd_Spectate, "Moves you to the spectator team");
	RegConsoleCmd("sm_away", Cmd_Spectate, "Moves you to the spectator team");
	RegConsoleCmd("sm_idle", Cmd_Spectate, "Moves you to the spectator team");
	RegConsoleCmd("sm_spectators", Cmd_Spectate, "Moves you to the spectator team");
	RegConsoleCmd("sm_joinspectators", Cmd_Spectate, "Moves you to the spectator team");
	RegConsoleCmd("sm_jointeam1", Cmd_Spectate, "Moves you to the spectator team");

	// Join a playing team
	RegConsoleCmd("sm_survivors", Cmd_JoinSurvivors, "Joins the survivor team");
	RegConsoleCmd("sm_joinsurvivors", Cmd_JoinSurvivors, "Joins the survivor team");
	RegConsoleCmd("sm_jointeam2", Cmd_JoinSurvivors, "Joins the survivor team");
	RegConsoleCmd("sm_infected", Cmd_JoinInfected, "Joins the infected team");
	RegConsoleCmd("sm_joininfected", Cmd_JoinInfected, "Joins the infected team");
	RegConsoleCmd("sm_jointeam3", Cmd_JoinInfected, "Joins the infected team");

	// Admin menu
	RegAdminCmd("sm_movetospec", Cmd_MoveToSpec, ADMFLAG_GENERIC, "Opens a menu allowing an admin to move a player to spectator.");
	RegAdminCmd("sm_mts", Cmd_MoveToSpec, ADMFLAG_GENERIC, "Opens a menu allowing an admin to move a player to spectator.");
}

/*
 * ============================
 * Player -> Spectator
 * ============================
 */

public Action Cmd_Spectate(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;

	if (CommandExists("sm_spectate"))
		FakeClientCommand(client, "sm_spectate");
	else
		ChangeClientTeam(client, 1);

	return Plugin_Handled;
}

/*
 * ============================
 * Player -> Survivors / Infected
 * ============================
 */

public Action Cmd_JoinSurvivors(int client, int args)
{
	if (client > 0 && IsClientInGame(client) && GetClientTeam(client) != 2)
		ClientCommand(client, "jointeam 2");

	return Plugin_Handled;
}

public Action Cmd_JoinInfected(int client, int args)
{
	if (client > 0 && IsClientInGame(client) && GetClientTeam(client) != 3)
		ClientCommand(client, "jointeam 3");

	return Plugin_Handled;
}

/*
 * ============================
 * !mts / !movetospec
 * ============================
 */

public Action Cmd_MoveToSpec(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
	{
		ReplyToCommand(client, "[Team Management] This command can only be used in-game. Use sm_swapto 1 <player> instead.");
		return Plugin_Handled;
	}

	ShowMoveToSpecMenu(client);
	return Plugin_Handled;
}

void ShowMoveToSpecMenu(int admin)
{
	Menu menu = new Menu(MenuHandler_MoveToSpec);
	menu.SetTitle("Move Player to Spectator");

	char userid[16], displayName[80];
	bool found = false;

	// Survivors first, then infected
	for (int team = 2; team <= 3; team++)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != team)
				continue;

			IntToString(GetClientUserId(i), userid, sizeof(userid));
			FormatEx(displayName, sizeof(displayName), "%N (%s)", i, team == 2 ? "Survivor" : "Infected");
			menu.AddItem(userid, displayName);
			found = true;
		}
	}

	if (!found)
	{
		delete menu;
		PrintToChat(admin, "[Team Management] \x04No players\x01 are currently on Survivors or Infected.");
		return;
	}

	menu.ExitButton = true;
	menu.Display(admin, MENU_TIME_FOREVER);
}

public int MenuHandler_MoveToSpec(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));
			int userid = StringToInt(info);
			int target = GetClientOfUserId(userid);

			if (target == 0 || !IsClientInGame(target))
			{
				PrintToChat(param1, "[Team Management] \x04That player is no longer in the game.");
				ShowMoveToSpecMenu(param1);
				return 0;
			}

			int team = GetClientTeam(target);
			if (team != 2 && team != 3)
			{
				PrintToChat(param1, "[Team Management] \x04%N\x01 is no longer on a playable team.", target);
				ShowMoveToSpecMenu(param1);
				return 0;
			}

			if (CommandExists("sm_swapto"))
				ServerCommand("sm_swapto 1 #%d", userid);
			else
				ChangeClientTeam(target, 1);

			PrintToChatAll("[Team Management] \x04%N\x01 moved \x03%N\x01 from %s to Spectator.",
				param1, target, team == 2 ? "Survivors" : "Infected");

			// sm_swapto runs on the next server frame; reopen the menu after it.
			CreateTimer(0.3, Timer_ReopenMenu, GetClientUserId(param1), TIMER_FLAG_NO_MAPCHANGE);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

public Action Timer_ReopenMenu(Handle timer, int adminUserId)
{
	int admin = GetClientOfUserId(adminUserId);
	if (admin > 0 && IsClientInGame(admin))
		ShowMoveToSpecMenu(admin);
	return Plugin_Stop;
}
