#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <multicolors>

#undef REQUIRE_PLUGIN
#tryinclude <readyup>

#define PLUGIN_VERSION "1.0"

#define G_flTickInterval 0.25
#define SHUFFLE_VOTE_TIME 15.0

public Plugin myinfo =
{
	name = "L4D2 Mix and Shuffle",
	author = "Vann09",
	description = "L4D2 Mix and Shuffle",
	version = PLUGIN_VERSION,
	url = ""
};


// =====================================================
// GAME
// =====================================================

bool g_bL4D2Version;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();

	if(test == Engine_Left4Dead)
	{
		g_bL4D2Version = false;
	}
	else if(test == Engine_Left4Dead2)
	{
		g_bL4D2Version = true;
	}
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}


// =====================================================
// CONVARS
// =====================================================

ConVar g_CvarSurvLimit;
ConVar g_CvarMaxPlayerZombies;

ConVar g_hPlayerSelectOrder;
ConVar g_hCvarSpectatorVote;
ConVar g_hCvarVoteSpectator;
ConVar g_hCvarChooseCaptain;


// =====================================================
// MIX STATE
// =====================================================

bool g_bTeamRequested[4];

int g_iPlayerSelectOrder;

bool g_bCvarSpectatorVote;
bool g_bCvarVoteSpectator;

int g_iMixCurStatus;
int g_iCvarChooseCaptain;

bool g_bSelectToggle;
int g_SelectToggleNum;

bool g_bHasVoted[MAXPLAYERS + 1];
bool g_bHasOneVoted;

bool g_bHasBeenChosen[MAXPLAYERS + 1];

bool g_lock;

int g_iSurvivorCaptain;
int g_iInfectedCaptain;

int g_iVotesSurvivorCaptain[MAXPLAYERS + 1];
int g_iVotesInfectedCaptain[MAXPLAYERS + 1];

int g_iDesignatedTeam[MAXPLAYERS + 1];
int g_iSelectedPlayers[MAXPLAYERS + 1];

char teamName[64];
char oppositeTeamName[64];

bool g_bGameStart;


// =====================================================
// SHUFFLE STATE
// =====================================================

bool g_bShuffleVoteInProgress;
bool g_bShuffleVoted[MAXPLAYERS + 1];

int g_iShuffleYesVotes;
int g_iShuffleNoVotes;
int g_iShuffleEligibleVotes;


// =====================================================
// PLUGIN START
// =====================================================

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
    LoadTranslations("l4d_mix.phrases");

	g_CvarSurvLimit = FindConVar("survivor_limit");
	g_CvarMaxPlayerZombies = FindConVar("z_max_player_zombies");

	g_hPlayerSelectOrder = CreateConVar(
		"l4d_mix_select_order",
		"1",
		"How captain choose the member, 0 = ABABAB | 1 = ABBAAB | 2 = ABBABA",
		FCVAR_NOTIFY,
		true,
		0.0,
		true,
		2.0
	);

	g_hCvarSpectatorVote = CreateConVar(
		"l4d_mix_spectator_vote",
		"1",
		"If 1, spectators can vote to choose the captain",
		FCVAR_NOTIFY,
		true,
		0.0,
		true,
		1.0
	);

	g_hCvarVoteSpectator = CreateConVar(
		"l4d_mix_vote_spectator",
		"1",
		"If 1, players can vote the spectators to be the captain + captains can choose spectators",
		FCVAR_NOTIFY,
		true,
		0.0,
		true,
		1.0
	);

	g_hCvarChooseCaptain = CreateConVar(
		"l4d_mix_choose_captain",
		"0",
		"How to select captain ? 0=Vote, 1=Random choose from survivor team and infected team",
		FCVAR_NOTIFY,
		true,
		0.0,
		true,
		1.0
	);

	CreateConVar(
		"l4d_mix_version",
		PLUGIN_VERSION,
		"l4d_mix Plugin Version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD | FCVAR_SPONLY
	);

	AutoExecConfig(true, "l4d_mix");

	// =================================================
	// MIX COMMANDS
	// =================================================

	RegConsoleCmd(
		"sm_mix",
		Command_Captainvote,
		"Initiate a player mix."
	);

	RegAdminCmd(
		"sm_forcemix",
		Command_ForceCaptainvote,
		ADMFLAG_ROOT,
		"Initiate a player mix. Admins only."
	);

	// =================================================
	// SHUFFLE COMMAND
	// =================================================

	RegConsoleCmd(
		"sm_shuffle",
		Command_Shuffle,
		"Shuffle players between Survivors and Infected."
	);

	MixStatus_Changed(0);

	GetCvars();

	g_hPlayerSelectOrder.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarSpectatorVote.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarVoteSpectator.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarChooseCaptain.AddChangeHook(ConVarChanged_Cvars);

	HookEvent("round_start", Event_RoundStart);

	if(g_bL4D2Version)
	{
		HookEvent(
			"survival_round_start",
			Event_SurvivalRoundStart,
			EventHookMode_PostNoCopy
		);

		HookEvent(
			"scavenge_round_start",
			Event_ScavengeRoundStart,
			EventHookMode_PostNoCopy
		);
	}
	else
	{
		HookEvent(
			"create_panic_event",
			Event_SurvivalRoundStart,
			EventHookMode_PostNoCopy
		);
	}

	HookEvent("round_end", Event_RoundEnd);
}


// =====================================================
// CVARS
// =====================================================

void ConVarChanged_Cvars(
	ConVar hCvar,
	const char[] sOldVal,
	const char[] sNewVal
)
{
	GetCvars();
}

void GetCvars()
{
	g_iPlayerSelectOrder = g_hPlayerSelectOrder.IntValue;
	g_bCvarSpectatorVote = g_hCvarSpectatorVote.BoolValue;
	g_bCvarVoteSpectator = g_hCvarVoteSpectator.BoolValue;
	g_iCvarChooseCaptain = g_hCvarChooseCaptain.IntValue;
}


// =====================================================
// MAP EVENTS
// =====================================================

public void OnMapStart()
{
	MixStatus_Changed(0);
	ResetShuffleVote();
}

public void OnMapEnd()
{
	MixStatus_Changed(0);
	ResetShuffleVote();
}

void Event_RoundStart(
	Event event,
	const char[] name,
	bool dontBroadcast
)
{
	g_lock = false;
	g_bGameStart = false;

	ResetShuffleVote();
	MixStatus_Changed(0);
}

void Event_SurvivalRoundStart(
	Event event,
	const char[] name,
	bool dontBroadcast
)
{
	if(g_bGameStart || L4D_GetGameModeType() != GAMEMODE_SURVIVAL)
		return;

	g_bGameStart = true;

	ResetShuffleVote();
}

void Event_ScavengeRoundStart(
	Event event,
	const char[] name,
	bool dontBroadcast
)
{
	g_bGameStart = true;

	ResetShuffleVote();
}

void Event_RoundEnd(
	Event event,
	const char[] name,
	bool dontBroadcast
)
{
	ResetShuffleVote();
	MixStatus_Changed(0);
}


// =====================================================
// CLIENT DISCONNECT
// =====================================================

public void OnClientDisconnect(int client)
{
	if(!g_bShuffleVoteInProgress)
		return;

	if(g_bShuffleVoted[client])
	{
		g_iShuffleYesVotes--;

		if(g_iShuffleYesVotes < 0)
			g_iShuffleYesVotes = 0;

		g_bShuffleVoted[client] = false;
	}

	RecalculateShuffleEligiblePlayers();

	if(g_iShuffleEligibleVotes < 2)
	{
		FinishShuffleVote(false);
		return;
	}

	// A disconnect can cause the existing YES votes
	// to become a majority.
	if(g_iShuffleYesVotes >= GetShuffleMajority())
	{
		FinishShuffleVote(true);
	}
}


// =====================================================
// !MIX
// =====================================================

Action Command_Captainvote(int client, int args)
{
	if(client == 0)
	{
		PrintToServer("[Mix] This command cannot be used by server.");
		return Plugin_Handled;
	}

	if(g_bGameStart)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Can't start a mix, the game has started!"
		);

		return Plugin_Handled;
	}

	int surfreeslots = GetTeamMaxHumans(2);
	int inffreeslots = GetTeamMaxHumans(3);
	int freeslots = surfreeslots + inffreeslots;
	int real_players = checkrealplayerinSV(true);

	if(freeslots > real_players)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Can't start a mix, not enough players ({red}%d{default}/{green}%d{default}).",
			real_players,
			freeslots
		);

		return Plugin_Handled;
	}

	if(surfreeslots == 1 && inffreeslots == 1)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Why you two start a mix in 1v1 ? Joke Game."
		);

		return Plugin_Handled;
	}

	if(surfreeslots == 1 || inffreeslots == 1)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Can't start a mix, not enough game slots({green}%d{default}-{green}%d{default})",
			surfreeslots,
			inffreeslots
		);

		return Plugin_Handled;
	}

	char CommandArgs[128];
	GetCmdArgString(CommandArgs, sizeof(CommandArgs));

	if(args > 0)
	{
		if(
			g_iMixCurStatus &&
			g_bTeamRequested[2] &&
			g_bTeamRequested[3]
		)
		{
			if(
				GetClientTeam(client) == L4D_TEAM_SURVIVOR ||
				GetClientTeam(client) == L4D_TEAM_INFECTED
			)
			{
				if(StrEqual(CommandArgs, "cancel", true))
				{
					MixStatus_Changed(5);

					CPrintToChatAll(
						"[{olive}Mix{default}] {lightgreen}%N {olive}cancelled the mix request.",
						client
					);
				}
			}
			else
			{
				CPrintToChat(
					client,
					"[{olive}Mix{default}] Spectators cannot cancel a mix."
				);
			}
		}
		else
		{
			CPrintToChat(
				client,
				"[{olive}Mix{default}] Nothing to cancel."
			);
		}

		return Plugin_Handled;
	}

	if(g_iMixCurStatus > 0)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] A mix is already in process."
		);

		return Plugin_Handled;
	}

	if(GetClientTeam(client) == L4D_TEAM_SPECTATOR)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Spectators cannot start a mix."
		);

		return Plugin_Handled;
	}

	int TeamID = GetClientTeam(client);

	if(!g_lock)
	{
		if(TeamID == L4D_TEAM_SURVIVOR)
		{
			strcopy(teamName, sizeof(teamName), "{blue}Survivors{default}");
			strcopy(oppositeTeamName, sizeof(oppositeTeamName), "{red}Infected{default}");
		}
		else if(TeamID == L4D_TEAM_INFECTED)
		{
			strcopy(teamName, sizeof(teamName), "{red}Infected{default}");
			strcopy(oppositeTeamName, sizeof(oppositeTeamName), "{blue}Survivors{default}");
		}
	}

	if(g_bTeamRequested[TeamID])
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Your team already requested a mix."
		);

		return Plugin_Handled;
	}

	g_bTeamRequested[TeamID] = true;

	if(g_bTeamRequested[2] && g_bTeamRequested[3])
	{
		CPrintToChatAll(
			"[{olive}Mix{default}] The %s have agreed to start the mix.",
			oppositeTeamName
		);

		MixStatus_Changed(0);
		MixStatus_Changed(1);

		if(g_iCvarChooseCaptain == 0)
		{
			DisplayVoteMenuCaptainSurvivor();
		}
		else
		{
			RandomChooseCaptain();
		}

		return Plugin_Handled;
	}

	CPrintToChatAll(
		"[{olive}Mix{default}] The %s have requested to start a mix.",
		teamName
	);

	CPrintToChatAll(
		"{default}The %s must agree by typing {green}!mix.",
		oppositeTeamName
	);

	g_lock = true;

	CreateTimer(
		10.0,
		Timer_LoadMix,
		_,
		TIMER_FLAG_NO_MAPCHANGE
	);

	return Plugin_Handled;
}


// =====================================================
// !FORCEMIX
// =====================================================

Action Command_ForceCaptainvote(int client, int args)
{
	if(client == 0)
	{
		PrintToServer("[Mix] This command cannot be used by server.");
		return Plugin_Handled;
	}

	if(g_bGameStart)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Can't start a mix, the game has started!"
		);

		return Plugin_Handled;
	}

	int surfreeslots = GetTeamMaxHumans(2);
	int inffreeslots = GetTeamMaxHumans(3);
	int freeslots = surfreeslots + inffreeslots;
	int real_players = checkrealplayerinSV(true);

	if(freeslots > real_players)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Can't start a mix, not enough players ({red}%d{default}/{green}%d{default}).",
			real_players,
			freeslots
		);

		return Plugin_Handled;
	}

	if(surfreeslots == 1 && inffreeslots == 1)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Why you two start a mix in 1v1 ? Joke Game."
		);

		return Plugin_Handled;
	}

	if(surfreeslots == 1 || inffreeslots == 1)
	{
		CPrintToChat(
			client,
			"[{olive}Mix{default}] Can't start a mix, not enough game slots({green}%d{default}-{green}%d{default})",
			surfreeslots,
			inffreeslots
		);

		return Plugin_Handled;
	}

	CPrintToChatAll(
		"[{olive}Mix{default}] Admin %N forces to start a mix!",
		client
	);

	g_lock = false;

	MixStatus_Changed(0);
	MixStatus_Changed(1);

	if(g_iCvarChooseCaptain == 0)
	{
		DisplayVoteMenuCaptainSurvivor();
	}
	else
	{
		RandomChooseCaptain();
	}

	return Plugin_Handled;
}


// =====================================================
// MIX REQUEST TIMEOUT
// =====================================================

Action Timer_LoadMix(Handle timer)
{
	if(g_iMixCurStatus > 0)
		return Plugin_Handled;

	g_bTeamRequested[2] = false;
	g_bTeamRequested[3] = false;

	if(g_lock)
	{
		CPrintToChatAll(
			"[{olive}Mix{default}] Mix request timed out."
		);

		g_lock = false;
	}

	return Plugin_Handled;
}


// =====================================================
// SURVIVOR CAPTAIN VOTE
// =====================================================

void DisplayVoteMenuCaptainSurvivor()
{
	if(g_iMixCurStatus <= 0)
		return;

	MixStatus_Changed(2);

	Menu SurvivorCaptainMenu = new Menu(
		Handler_SurvivorCaptainCallback,
		MENU_ACTIONS_DEFAULT
	);

	SurvivorCaptainMenu.SetTitle(
		"選隊長#1(Choose Survivor Captain):"
	);

	char name[32];
	char number[12];

	g_bHasOneVoted = false;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if(
			!g_bCvarVoteSpectator &&
			GetClientTeam(i) <= L4D_TEAM_SPECTATOR
		)
		{
			continue;
		}

		Format(name, sizeof(name), "%N", i);
		Format(number, sizeof(number), "%d", GetClientUserId(i));

		SurvivorCaptainMenu.AddItem(number, name, ITEMDRAW_DEFAULT);
	}

	SurvivorCaptainMenu.ExitButton = true;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if(
			!g_bCvarSpectatorVote &&
			GetClientTeam(i) <= L4D_TEAM_SPECTATOR
		)
		{
			continue;
		}

		SurvivorCaptainMenu.Display(i, 15);
	}

	CreateTimer(
		15.1,
		TimerCheckSurvivorCaptainVote,
		_,
		TIMER_FLAG_NO_MAPCHANGE
	);
}

Action TimerCheckSurvivorCaptainVote(Handle timer)
{
	if(g_iMixCurStatus <= 0)
		return Plugin_Stop;

	if(!g_bHasOneVoted)
	{
		DisplayVoteMenuCaptainSurvivor();
	}
	else
	{
		CalculateSurvivorCaptain();

		if(!IsValidClient(g_iSurvivorCaptain))
		{
			CPrintToChatAll(
				"[{olive}Mix{default}] Surprise! First Chosen Captain left the server, stopped the mix process."
			);

			MixStatus_Changed(5);

			return Plugin_Stop;
		}

		CPrintToChatAll(
			"[{olive}Mix{default}] First captain: {lightgreen}%N{default} With {green}%i {default}votes.",
			g_iSurvivorCaptain,
			g_iVotesSurvivorCaptain[g_iSurvivorCaptain]
		);

		DisplayVoteMenuCaptainInfected();
	}

	return Plugin_Stop;
}

int Handler_SurvivorCaptainCallback(
	Menu menu,
	MenuAction action,
	int param1,
	int param2
)
{
	switch(action)
	{
		case MenuAction_Select:
		{
			char item[16];

			menu.GetItem(
				param2,
				item,
				sizeof(item)
			);

			int target = GetClientOfUserId(
				StringToInt(item)
			);

			if(
				target > 0 &&
				IsClientInGame(target) &&
				!IsFakeClient(target)
			)
			{
				g_iVotesSurvivorCaptain[target]++;
				g_bHasOneVoted = true;
			}
			else
			{
				CPrintToChat(
					param1,
					"Target is not in game!"
				);
			}
		}

		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}


// =====================================================
// INFECTED CAPTAIN VOTE
// =====================================================

void DisplayVoteMenuCaptainInfected()
{
	Menu InfectedCaptainMenu = new Menu(
		Handler_InfectedCaptainCallback,
		MENU_ACTIONS_DEFAULT
	);

	InfectedCaptainMenu.SetTitle(
		"選隊長#2(Choose Infected Captain):"
	);

	char name[32];
	char number[12];

	g_bHasOneVoted = false;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if(i == g_iSurvivorCaptain)
			continue;

		if(
			!g_bCvarVoteSpectator &&
			GetClientTeam(i) <= L4D_TEAM_SPECTATOR
		)
		{
			continue;
		}

		Format(name, sizeof(name), "%N", i);
		Format(number, sizeof(number), "%d", GetClientUserId(i));

		InfectedCaptainMenu.AddItem(
			number,
			name,
			ITEMDRAW_DEFAULT
		);
	}

	InfectedCaptainMenu.ExitButton = true;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		InfectedCaptainMenu.Display(i, 15);
	}

	CreateTimer(
		15.1,
		TimerCheckInfectedCaptainVote,
		_,
		TIMER_FLAG_NO_MAPCHANGE
	);
}

Action TimerCheckInfectedCaptainVote(Handle timer)
{
	if(g_iMixCurStatus <= 0)
		return Plugin_Stop;

	if(!g_bHasOneVoted)
	{
		DisplayVoteMenuCaptainInfected();
	}
	else
	{
		CalculateInfectedCaptain();

		if(!IsValidClient(g_iInfectedCaptain))
		{
			CPrintToChatAll(
				"[{olive}Mix{default}] Surprise! Second Chosen Captain left the server, stopped the mix process."
			);

			MixStatus_Changed(5);

			return Plugin_Stop;
		}

		CPrintToChatAll(
			"[{olive}Mix{default}] Second captain: {lightgreen}%N{default} With {green}%i {default}votes.",
			g_iInfectedCaptain,
			g_iVotesInfectedCaptain[g_iInfectedCaptain]
		);

		MixStatus_Changed(3);
	}

	return Plugin_Stop;
}

int Handler_InfectedCaptainCallback(
	Menu menu,
	MenuAction action,
	int param1,
	int param2
)
{
	switch(action)
	{
		case MenuAction_Select:
		{
			char item[16];

			menu.GetItem(
				param2,
				item,
				sizeof(item)
			);

			int target = GetClientOfUserId(
				StringToInt(item)
			);

			if(
				target > 0 &&
				IsClientInGame(target) &&
				!IsFakeClient(target)
			)
			{
				g_iVotesInfectedCaptain[target]++;
				g_bHasOneVoted = true;
			}
			else
			{
				CPrintToChat(
					param1,
					"Target is not in game!"
				);
			}
		}

		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}


// =====================================================
// PLAYER SELECTION
// =====================================================

void DisplayVoteMenuPlayerSelect()
{
	Menu PlayerSelectMenu = new Menu(
		Handler_PlayerSelectionCallback,
		MENU_ACTIONS_DEFAULT
	);

	PlayerSelectMenu.SetTitle(
		"選隊員(Choose wisely...)"
	);

	char name[32];
	char number[12];

	for(int i = 1; i <= MaxClients; i++)
	{
		if(
			!IsClientInGame(i) ||
			IsFakeClient(i) ||
			g_bHasBeenChosen[i] ||
			i == g_iSurvivorCaptain ||
			i == g_iInfectedCaptain
		)
		{
			continue;
		}

		if(
			!g_bCvarVoteSpectator &&
			GetClientTeam(i) <= L4D_TEAM_SPECTATOR
		)
		{
			continue;
		}

		Format(name, sizeof(name), "%N", i);
		Format(number, sizeof(number), "%d", GetClientUserId(i));

		PlayerSelectMenu.AddItem(
			number,
			name,
			ITEMDRAW_DEFAULT
		);
	}

	PlayerSelectMenu.ExitButton = true;

	if(!IsValidClient(g_iSurvivorCaptain))
	{
		CPrintToChatAll(
			"[{olive}Mix{default}] Surprise! First Captain left the server, stopped the mix process."
		);

		MixStatus_Changed(5);
		delete PlayerSelectMenu;

		return;
	}

	if(!IsValidClient(g_iInfectedCaptain))
	{
		CPrintToChatAll(
			"[{olive}Mix{default}] Surprise! Second Captain left the server, stopped the mix process."
		);

		MixStatus_Changed(5);
		delete PlayerSelectMenu;

		return;
	}

	if(!g_bSelectToggle)
	{
		PlayerSelectMenu.Display(
			g_iSurvivorCaptain,
			3
		);
	}
	else
	{
		PlayerSelectMenu.Display(
			g_iInfectedCaptain,
			3
		);
	}

	CreateTimer(
		3.1,
		Timer_PlayerSelection,
		_,
		TIMER_FLAG_NO_MAPCHANGE
	);
}

int Handler_PlayerSelectionCallback(
	Menu menu,
	MenuAction action,
	int param1,
	int param2
)
{
	switch(action)
	{
		case MenuAction_Select:
		{
			char item[16];

			menu.GetItem(
				param2,
				item,
				sizeof(item)
			);

			int target = GetClientOfUserId(
				StringToInt(item)
			);

			if(
				target > 0 &&
				IsClientInGame(target) &&
				!IsFakeClient(target)
			)
			{
				g_bHasBeenChosen[target] = true;

				if(!g_bSelectToggle)
				{
					g_iDesignatedTeam[target] = L4D_TEAM_SURVIVOR;

					CPrintToChatAll(
						"[{olive}Mix{default}] {blue}%N {default}selected: {green}%N",
						g_iSurvivorCaptain,
						target
					);

					g_iSelectedPlayers[g_iSurvivorCaptain]++;
				}
				else
				{
					g_iDesignatedTeam[target] = L4D_TEAM_INFECTED;

					CPrintToChatAll(
						"[{olive}Mix{default}] {red}%N {default}selected: {green}%N",
						g_iInfectedCaptain,
						target
					);

					g_iSelectedPlayers[g_iInfectedCaptain]++;
				}

				g_SelectToggleNum++;

				switch(g_iPlayerSelectOrder)
				{
					case 0:
					{
						// ABABAB
						g_bSelectToggle = !g_bSelectToggle;
					}

					case 1:
					{
						// ABBAAB
						if(g_SelectToggleNum % 2 == 0)
							g_bSelectToggle = !g_bSelectToggle;
					}

					case 2:
					{
						// ABBABA
						if(g_SelectToggleNum >= 5)
							g_bSelectToggle = !g_bSelectToggle;
						else if(g_SelectToggleNum % 2 == 0)
							g_bSelectToggle = !g_bSelectToggle;
					}
				}
			}
			else
			{
				CPrintToChat(
					param1,
					"[{olive}Mix{default}] This player has left the server, choose again!"
				);
			}
		}

		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

Action Timer_PlayerSelection(Handle timer)
{
	if(g_iMixCurStatus <= 0)
		return Plugin_Stop;

	int SurvivorLimit = g_CvarSurvLimit.IntValue;
	int InfectedLimit = g_CvarMaxPlayerZombies.IntValue;

	if(
		g_iSelectedPlayers[g_iSurvivorCaptain] >= SurvivorLimit - 1 &&
		g_iSelectedPlayers[g_iInfectedCaptain] >= InfectedLimit - 1
	)
	{
		MixStatus_Changed(4);
		return Plugin_Stop;
	}

	int freeslots = SurvivorLimit + InfectedLimit;
	int real_players = checkrealplayerinSV();

	if(freeslots > real_players)
	{
		CPrintToChatAll(
			"[{olive}Mix{default}] Not enough players in server({red}%d{default}/{green}%d{default}), stopped the mix process.",
			real_players,
			freeslots
		);

		MixStatus_Changed(5);

		return Plugin_Stop;
	}

	DisplayVoteMenuPlayerSelect();

	return Plugin_Stop;
}


// =====================================================
// MIX RESET FUNCTIONS
// =====================================================

void ResetCaptains()
{
	g_iSurvivorCaptain = 0;
	g_iInfectedCaptain = 0;
}

void ResetAllVotes()
{
	for(int i = 1; i <= MaxClients; i++)
	{
		g_iVotesSurvivorCaptain[i] = 0;
		g_iVotesInfectedCaptain[i] = 0;
	}
}

void ResetTeams()
{
	for(int i = 1; i <= MaxClients; i++)
	{
		g_iDesignatedTeam[i] = 1;
	}
}

void ResetSelectedPlayers()
{
	for(int i = 1; i <= MaxClients; i++)
	{
		g_iSelectedPlayers[i] = 0;
		g_bHasBeenChosen[i] = false;
	}
}

void CalculateSurvivorCaptain()
{
	int highestvotes;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(g_iVotesSurvivorCaptain[i] > highestvotes)
		{
			highestvotes = g_iVotesSurvivorCaptain[i];
			g_iSurvivorCaptain = i;
			g_iDesignatedTeam[i] = L4D_TEAM_SURVIVOR;
		}
	}
}

void CalculateInfectedCaptain()
{
	int highestvotes;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(g_iVotesInfectedCaptain[i] > highestvotes)
		{
			highestvotes = g_iVotesInfectedCaptain[i];
			g_iInfectedCaptain = i;
			g_iDesignatedTeam[i] = L4D_TEAM_INFECTED;
		}
	}
}

void ResetHasVoted()
{
	g_bHasOneVoted = false;

	for(int i = 1; i <= MaxClients; i++)
	{
		g_bHasVoted[i] = false;
	}
}


// =====================================================
// MIX TEAM MOVEMENT
// =====================================================

void SwapPlayersToDesignatedTeams()
{
	g_iDesignatedTeam[g_iSurvivorCaptain] = L4D_TEAM_SURVIVOR;
	g_iDesignatedTeam[g_iInfectedCaptain] = L4D_TEAM_INFECTED;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(
			IsClientInGame(i) &&
			!IsFakeClient(i) &&
			GetClientTeam(i) != L4D_TEAM_SPECTATOR
		)
		{
			ChangeClientTeam(
				i,
				L4D_TEAM_SPECTATOR
			);
		}
	}

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if(g_iDesignatedTeam[i] == L4D_TEAM_SURVIVOR)
		{
			CreateTimer(
				G_flTickInterval,
				MoveToSurvivor,
				GetClientUserId(i),
				TIMER_FLAG_NO_MAPCHANGE
			);
		}
		else if(g_iDesignatedTeam[i] == L4D_TEAM_INFECTED)
		{
			CreateTimer(
				G_flTickInterval,
				MoveToInfected,
				GetClientUserId(i),
				TIMER_FLAG_NO_MAPCHANGE
			);
		}
	}

	MixStatus_Changed(0);
}

Action MoveToSurvivor(Handle timer, any userid)
{
	int targetplayer = GetClientOfUserId(userid);

	if(targetplayer <= 0 || !IsClientInGame(targetplayer))
		return Plugin_Stop;

	int bot = FindBotToTakeOver(true);

	if(bot == 0)
	{
		bot = FindBotToTakeOver(false);
	}

	if(bot > 0)
	{
		L4D_SetHumanSpec(bot, targetplayer);
		L4D_TakeOverBot(targetplayer);
	}

	return Plugin_Stop;
}

Action MoveToInfected(Handle timer, any userid)
{
	int targetplayer = GetClientOfUserId(userid);

	if(targetplayer <= 0 || !IsClientInGame(targetplayer))
		return Plugin_Stop;

	ChangeClientTeam(
		targetplayer,
		L4D_TEAM_INFECTED
	);

	return Plugin_Stop;
}


// =====================================================
// SHUFFLE COMMAND
// =====================================================

Action Command_Shuffle(int client, int args)
{
	if(client == 0)
	{
		PrintToServer(
			"[Shuffle] This command cannot be used by server."
		);

		return Plugin_Handled;
	}

	if(g_bGameStart)
	{
		CPrintToChat(
			client,
			"[{olive}Shuffle{default}] You cannot shuffle teams after the game has started."
		);

		return Plugin_Handled;
	}

	if(g_iMixCurStatus > 0)
	{
		CPrintToChat(
			client,
			"[{olive}Shuffle{default}] A mix is currently in progress."
		);

		return Plugin_Handled;
	}

	if(GetClientTeam(client) == L4D_TEAM_SPECTATOR)
	{
		CPrintToChat(
			client,
			"[{olive}Shuffle{default}] Spectators cannot start or vote for a shuffle."
		);

		return Plugin_Handled;
	}

	// =================================================
	// ADMIN = INSTANT SHUFFLE
	// =================================================

	if(CheckCommandAccess(
		client,
		"l4d_shuffle_admin",
		ADMFLAG_GENERIC,
		false
	))
	{
		// Cancel an existing public vote.
		if(g_bShuffleVoteInProgress)
		{
			ResetShuffleVote();
		}

		CPrintToChatAll(
			"[{olive}Shuffle{default}] Admin {lightgreen}%N{default} forced a team shuffle!",
			client
		);

		StartTeamShuffle();

		return Plugin_Handled;
	}

	// =================================================
	// PUBLIC PLAYER = VOTE
	// =================================================

	if(g_bShuffleVoteInProgress)
	{
		if(g_bShuffleVoted[client])
		{
			CPrintToChat(
				client,
				"[{olive}Shuffle{default}] You have already voted."
			);

			return Plugin_Handled;
		}

		CastShuffleVote(client);

		return Plugin_Handled;
	}

	StartShuffleVote(client);

	return Plugin_Handled;
}


// =====================================================
// START SHUFFLE VOTE
// =====================================================

void StartShuffleVote(int client)
{
	g_bShuffleVoteInProgress = true;

	g_iShuffleYesVotes = 0;
	g_iShuffleNoVotes = 0;
	g_iShuffleEligibleVotes = 0;

	for(int i = 1; i <= MaxClients; i++)
	{
		g_bShuffleVoted[i] = false;

		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		int team = GetClientTeam(i);

		// Spectators are NOT eligible.
		if(
			team == L4D_TEAM_SURVIVOR ||
			team == L4D_TEAM_INFECTED
		)
		{
			g_iShuffleEligibleVotes++;
		}
	}

	if(g_iShuffleEligibleVotes < 2)
	{
		ResetShuffleVote();

		CPrintToChat(
			client,
			"[{olive}Shuffle{default}] Not enough players to start a shuffle vote."
		);

		return;
	}

	CPrintToChatAll(
		"[{olive}Shuffle{default}] {lightgreen}%N{default} wants to shuffle the teams!",
		client
	);

	CPrintToChatAll(
		"[{olive}Shuffle{default}] Type {green}!shuffle{default} to vote YES."
	);

	CPrintToChatAll(
		"[{olive}Shuffle{default}] Need a majority: {green}%d{default}/{olive}%d{default} active players.",
		GetShuffleMajority(),
		g_iShuffleEligibleVotes
	);

	// The player who started the vote automatically votes YES.
	CastShuffleVote(client);

	CreateTimer(
		SHUFFLE_VOTE_TIME,
		Timer_ShuffleVoteEnd,
		_,
		TIMER_FLAG_NO_MAPCHANGE
	);
}


// =====================================================
// SHUFFLE VOTE
// =====================================================

int GetShuffleMajority()
{
	// Strict majority: more than 50%.
	return (g_iShuffleEligibleVotes / 2) + 1;
}

void CastShuffleVote(int client)
{
	if(!g_bShuffleVoteInProgress)
		return;

	if(!IsClientInGame(client) || IsFakeClient(client))
		return;

	int team = GetClientTeam(client);

	if(
		team != L4D_TEAM_SURVIVOR &&
		team != L4D_TEAM_INFECTED
	)
	{
		return;
	}

	if(g_bShuffleVoted[client])
		return;

	g_bShuffleVoted[client] = true;
	g_iShuffleYesVotes++;

	CPrintToChatAll(
		"[{olive}Shuffle{default}] {lightgreen}%N{default} voted YES. ({green}%d{default}/{olive}%d{default})",
		client,
		g_iShuffleYesVotes,
		GetShuffleMajority()
	);

	if(g_iShuffleYesVotes >= GetShuffleMajority())
	{
		FinishShuffleVote(true);
	}
}

Action Timer_ShuffleVoteEnd(Handle timer)
{
	if(!g_bShuffleVoteInProgress)
		return Plugin_Stop;

	FinishShuffleVote(false);

	return Plugin_Stop;
}

void FinishShuffleVote(bool passed)
{
	if(!g_bShuffleVoteInProgress)
		return;

	g_bShuffleVoteInProgress = false;

	if(passed)
	{
		CPrintToChatAll(
			"[{olive}Shuffle{default}] Majority reached! Shuffling teams..."
		);

		StartTeamShuffle();
	}
	else
	{
		CPrintToChatAll(
			"[{olive}Shuffle{default}] Vote failed. {green}%d{default}/{olive}%d{default} votes.",
			g_iShuffleYesVotes,
			GetShuffleMajority()
		);
	}

	g_iShuffleYesVotes = 0;
	g_iShuffleNoVotes = 0;
	g_iShuffleEligibleVotes = 0;

	for(int i = 1; i <= MaxClients; i++)
	{
		g_bShuffleVoted[i] = false;
	}
}

void ResetShuffleVote()
{
	g_bShuffleVoteInProgress = false;

	g_iShuffleYesVotes = 0;
	g_iShuffleNoVotes = 0;
	g_iShuffleEligibleVotes = 0;

	for(int i = 1; i <= MaxClients; i++)
	{
		g_bShuffleVoted[i] = false;
	}
}

void RecalculateShuffleEligiblePlayers()
{
	g_iShuffleEligibleVotes = 0;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		int team = GetClientTeam(i);

		if(
			team == L4D_TEAM_SURVIVOR ||
			team == L4D_TEAM_INFECTED
		)
		{
			g_iShuffleEligibleVotes++;
		}
	}
}


// =====================================================
// ACTUAL TEAM SHUFFLE
// =====================================================

void StartTeamShuffle()
{
	if(g_bGameStart)
		return;

	int players[MAXPLAYERS + 1];
	int playerCount = 0;

	int survivorCount = 0;
	int infectedCount = 0;

	// =================================================
	// COLLECT ACTIVE HUMAN PLAYERS
	//
	// Spectators are deliberately ignored.
	// Bots are deliberately ignored.
	// =================================================

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		int team = GetClientTeam(i);

		if(team == L4D_TEAM_SURVIVOR)
		{
			players[playerCount++] = i;
			survivorCount++;
		}
		else if(team == L4D_TEAM_INFECTED)
		{
			players[playerCount++] = i;
			infectedCount++;
		}
	}

	if(playerCount < 2)
	{
		CPrintToChatAll(
			"[{olive}Shuffle{default}] Not enough players to shuffle."
		);

		return;
	}

	if(survivorCount == 0 || infectedCount == 0)
	{
		CPrintToChatAll(
			"[{olive}Shuffle{default}] Both teams need at least one player."
		);

		return;
	}

	// =================================================
	// RANDOMIZE PLAYERS
	// =================================================

	ShufflePlayerArray(
		players,
		playerCount
	);

	// =================================================
	// PRESERVE CURRENT TEAM SIZES
	//
	// Example:
	// 5 Survivors + 3 Infected
	// becomes
	// 5 random Survivors + 3 random Infected
	// =================================================

	for(int i = 0; i < playerCount; i++)
	{
		int target = players[i];

		if(i < survivorCount)
		{
			g_iDesignatedTeam[target] = L4D_TEAM_SURVIVOR;
		}
		else
		{
			g_iDesignatedTeam[target] = L4D_TEAM_INFECTED;
		}
	}

	CPrintToChatAll(
		"[{olive}Shuffle{default}] Randomizing {green}%d{default} players ({blue}%d{default} Survivors / {red}%d{default} Infected)...",
		playerCount,
		survivorCount,
		infectedCount
	);

	// =================================================
	// MOVE EVERYONE TO SPECTATOR FIRST
	// =================================================

	for(int i = 0; i < playerCount; i++)
	{
		int target = players[i];

		if(
			IsClientInGame(target) &&
			GetClientTeam(target) != L4D_TEAM_SPECTATOR
		)
		{
			ChangeClientTeam(
				target,
				L4D_TEAM_SPECTATOR
			);
		}
	}

	// =================================================
	// MOVE TO NEW TEAMS
	// =================================================

	for(int i = 0; i < playerCount; i++)
	{
		int target = players[i];

		if(!IsClientInGame(target))
			continue;

		int userid = GetClientUserId(target);

		if(userid <= 0)
			continue;

		if(g_iDesignatedTeam[target] == L4D_TEAM_SURVIVOR)
		{
			CreateTimer(
				G_flTickInterval,
				MoveToSurvivor,
				userid,
				TIMER_FLAG_NO_MAPCHANGE
			);
		}
		else if(g_iDesignatedTeam[target] == L4D_TEAM_INFECTED)
		{
			CreateTimer(
				G_flTickInterval,
				MoveToInfected,
				userid,
				TIMER_FLAG_NO_MAPCHANGE
			);
		}
	}

	CreateTimer(
		1.0,
		Timer_PrintShuffleResult,
		_,
		TIMER_FLAG_NO_MAPCHANGE
	);
}


// =====================================================
// FISHER-YATES SHUFFLE
// =====================================================

void ShufflePlayerArray(int players[MAXPLAYERS + 1], int count)
{
	for (int i = count - 1; i > 0; i--)
	{
		int randomIndex = GetRandomInt(0, i);

		int temp = players[i];
		players[i] = players[randomIndex];
		players[randomIndex] = temp;
	}
}


// =====================================================
// SHUFFLE RESULT
// =====================================================

Action Timer_PrintShuffleResult(Handle timer)
{
	if(g_bGameStart)
		return Plugin_Stop;

	CPrintToChatAll(
		"[{olive}Shuffle{default}] Teams have been shuffled!"
	);

	CPrintToChatAll(
		"[{olive}Shuffle{default}] {blue}Survivors:"
	);

	for(int i = 1; i <= MaxClients; i++)
	{
		if(
			IsClientInGame(i) &&
			!IsFakeClient(i) &&
			GetClientTeam(i) == L4D_TEAM_SURVIVOR
		)
		{
			CPrintToChatAll(
				"  {green}%N",
				i
			);
		}
	}

	CPrintToChatAll(
		"[{olive}Shuffle{default}] {red}Infected:"
	);

	for(int i = 1; i <= MaxClients; i++)
	{
		if(
			IsClientInGame(i) &&
			!IsFakeClient(i) &&
			GetClientTeam(i) == L4D_TEAM_INFECTED
		)
		{
			CPrintToChatAll(
				"  {green}%N",
				i
			);
		}
	}

	return Plugin_Stop;
}


// =====================================================
// RANDOM CAPTAIN
// =====================================================

void RandomChooseCaptain()
{
	g_iSurvivorCaptain = GetRandomCaptain(true);
	g_iInfectedCaptain = GetRandomCaptain(false);

	if(
		g_iSurvivorCaptain == 0 ||
		g_iInfectedCaptain == 0
	)
	{
		CPrintToChatAll(
			"[{olive}Mix{default}] Unable to randomly select captain in survivor/infected team."
		);

		MixStatus_Changed(5);

		return;
	}

	CPrintToChatAll(
		"[{olive}Mix{default}] Sur. Captain: {lightgreen}%N{default}, Inf. Captain: {lightgreen}%N{default}",
		g_iSurvivorCaptain,
		g_iInfectedCaptain
	);

	MixStatus_Changed(3);
}

int GetRandomCaptain(bool bSurvivorTeam)
{
	int iClientCount;
	int iClients[MAXPLAYERS + 1];

	for(int i = 1; i <= MaxClients; i++)
	{
		if(
			IsClientInGame(i) &&
			!IsFakeClient(i)
		)
		{
			if(
				bSurvivorTeam &&
				GetClientTeam(i) == L4D_TEAM_SURVIVOR
			)
			{
				iClients[iClientCount++] = i;
			}
			else if(
				!bSurvivorTeam &&
				GetClientTeam(i) == L4D_TEAM_INFECTED
			)
			{
				iClients[iClientCount++] = i;
			}
		}
	}

	if(iClientCount == 0)
		return 0;

	return iClients[
		GetRandomInt(0, iClientCount - 1)
	];
}


// =====================================================
// MIX STATUS
//
// 0 = reset
// 1 = choose captain #1
// 2 = choose captain #2
// 3 = captains choose players
// 4 = teams ready
// 5 = mix terminated
// =====================================================

void MixStatus_Changed(int iMixCurStatus)
{
	g_iMixCurStatus = iMixCurStatus;

	if(iMixCurStatus == 0)
	{
		ResetSelectedPlayers();
		ResetTeams();
		ResetCaptains();
		ResetAllVotes();
		ResetHasVoted();

		g_bTeamRequested[2] = false;
		g_bTeamRequested[3] = false;
	}
	else if(iMixCurStatus == 1)
	{
		// Nothing.
	}
	else if(iMixCurStatus == 2)
	{
		// Nothing.
	}
	else if(iMixCurStatus == 3)
	{
		g_bSelectToggle = false;
		g_SelectToggleNum = 1;

		switch(g_iPlayerSelectOrder)
		{
			case 0:
			{
				CPrintToChatAll(
					"[{olive}Mix{default}] Captains will now begin to choose players(A-B-A-B-A-B)."
				);
			}

			case 1:
			{
				CPrintToChatAll(
					"[{olive}Mix{default}] Captains will now begin to choose players(A-BB-AA-B)."
				);
			}

			case 2:
			{
				CPrintToChatAll(
					"[{olive}Mix{default}] Captains will now begin to choose players(A-BB-A-B-A)."
				);
			}
		}

		DisplayVoteMenuPlayerSelect();
	}
	else if(iMixCurStatus == 4)
	{
		CPrintToChatAll(
			"[{olive}Mix{default}] Teams set, let the mix begin!"
		);

		SwapPlayersToDesignatedTeams();

		MixStatus_Changed(0);
	}
	else
	{
		MixStatus_Changed(0);
	}
}


// =====================================================
// GENERAL HELPERS
// =====================================================

bool IsValidClient(int client)
{
	if(client < 1 || client > MaxClients)
		return false;

	return IsClientInGame(client);
}

int GetTeamMaxHumans(int team)
{
	if(team == L4D_TEAM_SURVIVOR)
		return g_CvarSurvLimit.IntValue;

	if(team == L4D_TEAM_INFECTED)
		return g_CvarMaxPlayerZombies.IntValue;

	return -1;
}

int checkrealplayerinSV(bool bGame = false)
{
	int players;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if(bGame && GetClientTeam(i) <= L4D_TEAM_SPECTATOR)
			continue;

		players++;
	}

	return players;
}

int FindBotToTakeOver(bool alive)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(
			IsClientInGame(i) &&
			IsFakeClient(i) &&
			GetClientTeam(i) == L4D_TEAM_SURVIVOR &&
			!HasIdlePlayer(i) &&
			IsPlayerAlive(i) == alive
		)
		{
			return i;
		}
	}

	return 0;
}

bool HasIdlePlayer(int bot)
{
	if(!HasEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
		return false;

	return GetEntProp(
		bot,
		Prop_Send,
		"m_humanSpectatorUserID"
	) > 0;
}


// =====================================================
// LEFT4DHOOKS
// =====================================================

public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
{
	if(
		L4D_GetGameModeType() != GAMEMODE_SURVIVAL &&
		L4D_GetGameModeType() != GAMEMODE_SCAVENGE
	)
	{
		g_bGameStart = true;

		ResetShuffleVote();
	}
}


// =====================================================
// READYUP API
// =====================================================

public void OnRoundIsLive()
{
	g_bGameStart = true;

	ResetShuffleVote();
}