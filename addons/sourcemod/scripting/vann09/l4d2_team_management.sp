#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.2"
#define PLUGIN_NAME    "Team management"

public Plugin myinfo =
{
	name = PLUGIN_NAME,
	author = "Vann09",
	description = "Adds commands to let players spectate/join teams and admins move players to spectator.",
	version = PLUGIN_VERSION
};

public void OnPluginStart()
{
	CreateConVar(
		"afk_spectate_commands_version",
		PLUGIN_VERSION,
		"Team management plugin version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD
	);

	// Spectator commands
	RegConsoleCmd("sm_afk", AFKTurnClientToSpectate);
	RegConsoleCmd("sm_spec", AFKTurnClientToSpectate);
	RegConsoleCmd("sm_away", AFKTurnClientToSpectate);
	RegConsoleCmd("sm_idle", AFKTurnClientToSpectate);
	RegConsoleCmd("sm_spectate", AFKTurnClientToSpectate);
	RegConsoleCmd("sm_spectators", AFKTurnClientToSpectate);
	RegConsoleCmd("sm_joinspectators", AFKTurnClientToSpectate);

	// Survivor commands
	RegConsoleCmd("sm_jointeam1", AFKTurnClientToSpectate);
	RegConsoleCmd("sm_survivors", AFKTurnClientToSurvivors);
	RegConsoleCmd("sm_joinsurvivors", AFKTurnClientToSurvivors);
	RegConsoleCmd("sm_jointeam2", AFKTurnClientToSurvivors);

	// Infected commands
	RegConsoleCmd("sm_infected", AFKTurnClientToInfected);
	RegConsoleCmd("sm_joininfected", AFKTurnClientToInfected);
	RegConsoleCmd("sm_jointeam3", AFKTurnClientToInfected);

	// Admin command
	RegAdminCmd(
		"sm_movetospec",
		Command_MoveToSpec,
		ADMFLAG_GENERIC,
		"Opens a menu allowing an admin to move a player to spectator."
	);
	RegAdminCmd(
		"sm_mts",
		Command_MoveToSpec,
		ADMFLAG_GENERIC,
		"Opens a menu allowing an admin to move a player to spectator."
	);
}

/*
 * ============================
 * Player -> Spectator
 * ============================
 */

public Action AFKTurnClientToSpectate(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;

	ChangeClientTeam(client, 1);

	return Plugin_Handled;
}

/*
 * ============================
 * Player -> Survivors
 * ============================
 */

public Action AFKTurnClientToSurvivors(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;

	ClientCommand(client, "jointeam 2");

	return Plugin_Handled;
}

/*
 * ============================
 * Player -> Infected
 * ============================
 */

public Action AFKTurnClientToInfected(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;

	ClientCommand(client, "jointeam 3");

	return Plugin_Handled;
}

/*
 * ============================
 * !movetospec
 * ============================
 */

public Action Command_MoveToSpec(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
	{
		PrintToServer("[Team Management] This command can only be used in-game.");
		return Plugin_Handled;
	}

	ShowMoveToSpecMenu(client);

	return Plugin_Handled;
}

/*
 * ============================
 * Create the player menu
 * ============================
 */

void ShowMoveToSpecMenu(int admin)
{
	Menu menu = new Menu(MenuHandler_MoveToSpec);

	menu.SetTitle("Move Player to Spectator");

	char userid[16];
	char displayName[64];

	bool foundPlayers = false;

	/*
	 * Survivors
	 */

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (GetClientTeam(i) != 2)
			continue;

		IntToString(GetClientUserId(i), userid, sizeof(userid));
		Format(displayName, sizeof(displayName), "%N", i);

		menu.AddItem(userid, displayName);
		foundPlayers = true;
	}

	/*
	 * Infected
	 */

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (GetClientTeam(i) != 3)
			continue;

		IntToString(GetClientUserId(i), userid, sizeof(userid));
		Format(displayName, sizeof(displayName), "%N", i);

		menu.AddItem(userid, displayName);
		foundPlayers = true;
	}

	if (!foundPlayers)
	{
		delete menu;

		PrintToChat(
			admin,
			"[Team Management] \x04No players\x01 are currently on Survivors or Infected."
		);

		return;
	}

	menu.ExitButton = true;
	menu.Display(admin, MENU_TIME_FOREVER);
}

/*
 * ============================
 * Menu callback
 * ============================
 */

public int MenuHandler_MoveToSpec(
	Menu menu,
	MenuAction action,
	int param1,
	int param2
)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));

			int userid = StringToInt(info);
			int target = GetClientOfUserId(userid);

			/*
			 * Player may have disconnected while
			 * the menu was open.
			 */
			if (target == 0 || !IsClientInGame(target))
			{
				PrintToChat(
					param1,
					"[Team Management] \x04That player is no longer in the game."
				);

				ShowMoveToSpecMenu(param1);
				return 0;
			}

			int team = GetClientTeam(target);

			/*
			 * Make sure the selected player is
			 * actually on Survivors or Infected.
			 */
			if (team != 2 && team != 3)
			{
				PrintToChat(
					param1,
					"[Team Management] \x04%N\x01 is no longer on a playable team.",
					target
				);

				ShowMoveToSpecMenu(param1);
				return 0;
			}

			char teamName[32];

			if (team == 2)
			{
				strcopy(teamName, sizeof(teamName), "Survivors");
			}
			else
			{
				strcopy(teamName, sizeof(teamName), "Infected");
			}

			/*
			 * Move player to spectator.
			 */
			ChangeClientTeam(target, 1);

			PrintToChatAll(
				"[Team Management] \x04%N\x01 moved \x03%N\x01 from %s to Spectator.",
				param1,
				target,
				teamName
			);

			/*
			 * Re-open the menu so the admin can
			 * move another player immediately.
			 */
			if (IsClientInGame(param1))
			{
				ShowMoveToSpecMenu(param1);
			}
		}

		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}