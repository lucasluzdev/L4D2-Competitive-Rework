#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>

#define PLUGIN_VERSION "1.1"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZC_TANK       8

/*
 * Admin tools for bugged tank spawns:
 *   !fixtank [here]              - moves the alive tank (stuck under the map / in a wall) to a new
 *                                  valid spawn spot, keeping its health and its player.
 *                                  "here" = spot where the admin is aiming.
 *   !spawntank [player]          - spawns a new tank at a valid spot near the leading survivor
 *                                  (tank died instantly / never spawned).
 *   !spawntankhere [player]      - same, at the spot where the admin is aiming.
 *   [player] (optional)          - infected player who takes control of the new tank.
 *                                  Without it: the admin if on the infected team, else a random infected player
 *                                  (AI only when the infected team has no human).
 *
 * Spawning a tank manually cancels this half's flow tank, so the original one can't show up later
 * as a second tank. The other half keeps its normal flow tank.
 */

public Plugin myinfo =
{
	name = "L4D2 Tank Tools",
	author = "Vann09",
	description = "Admin commands to move a stuck tank or force a tank spawn.",
	version = PLUGIN_VERSION
};

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("l4d2_tank_tools.phrases");
	CreateConVar("l4d2_tank_tools_version", PLUGIN_VERSION, "L4D2 Tank Tools version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	RegAdminCmd("sm_fixtank", Cmd_FixTank, ADMFLAG_GENERIC, "sm_fixtank [here] - moves the alive tank to a new valid spot (keeps health and player)");
	RegAdminCmd("sm_spawntank", Cmd_SpawnTank, ADMFLAG_GENERIC, "sm_spawntank [player] - spawns a tank at a valid spot near the survivors");
	RegAdminCmd("sm_spawntankhere", Cmd_SpawnTankHere, ADMFLAG_GENERIC, "sm_spawntankhere [player] - spawns a tank where you are aiming");
}

/*
 * ============================
 * !fixtank
 * ============================
 */

public Action Cmd_FixTank(int client, int args)
{
	char arg[16];
	if (args >= 1)
		GetCmdArg(1, arg, sizeof(arg));
	bool here = StrEqual(arg, "here", false);

	if (here && !IsInGameClient(client))
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "InGameOnly", client);
		return Plugin_Handled;
	}

	int moved = 0;
	float pos[3];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsAliveTank(i))
			continue;

		bool found = here ? GetAimSpot(client, pos) : GetSpawnSpot(pos);
		if (!found)
		{
			CReplyToCommand(client, "%T %T", "Tag", client, "NoPosition", client);
			return Plugin_Handled;
		}
		TeleportEntity(i, pos, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
		moved++;
	}

	if (moved == 0)
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "NoTank", client);
		return Plugin_Handled;
	}

	PrintToAll("Moved", client);
	LogAction(client, -1, "\"%L\" moved the tank (%s)", client, here ? "crosshair" : "random spot");
	return Plugin_Handled;
}

/*
 * ============================
 * !spawntank / !spawntankhere
 * ============================
 */

public Action Cmd_SpawnTank(int client, int args)
{
	return DoSpawnTank(client, args, false);
}

public Action Cmd_SpawnTankHere(int client, int args)
{
	return DoSpawnTank(client, args, true);
}

Action DoSpawnTank(int client, int args, bool here)
{
	if (here && !IsInGameClient(client))
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "InGameOnly", client);
		return Plugin_Handled;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsAliveTank(i))
		{
			CReplyToCommand(client, "%T %T", "Tag", client, "TankAlive", client);
			return Plugin_Handled;
		}
	}

	// Optional player who takes the new tank
	int target = 0;
	if (args >= 1)
	{
		char arg[MAX_NAME_LENGTH];
		GetCmdArg(1, arg, sizeof(arg));
		target = FindTarget(client, arg, true, false);
		if (target == -1)
			return Plugin_Handled;
		if (GetClientTeam(target) != TEAM_INFECTED)
		{
			CReplyToCommand(client, "%T %T", "Tag", client, "NotInfected", client, target);
			return Plugin_Handled;
		}
	}
	else
	{
		// No player given: the admin takes it if on the infected team, otherwise a random infected player.
		// Only stays AI when there is no human on the infected team.
		target = PickDefaultTarget(client);
	}

	float pos[3];
	bool found = here ? GetAimSpot(client, pos) : GetSpawnSpot(pos);
	if (!found)
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "NoPosition", client);
		return Plugin_Handled;
	}

	float ang[3];
	if (IsInGameClient(client))
	{
		// Face the admin (crosshair) or the leading survivor
		float from[3];
		GetClientAbsOrigin(client, from);
		MakeVectorFromPoints(pos, from, ang);
		GetVectorAngles(ang, ang);
		ang[0] = 0.0;
		ang[2] = 0.0;
	}

	int tank = L4D2_SpawnTank(pos, ang);
	if (tank <= 0)
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "SpawnFailed", client);
		return Plugin_Handled;
	}

	// The manual tank replaces this half's flow tank (no double tank later).
	int half = GameRules_GetProp("m_bInSecondHalfOfRound") ? 1 : 0;
	L4D2Direct_SetVSTankToSpawnThisRound(half, false);

	if (target > 0)
	{
		DataPack dp;
		CreateDataTimer(0.1, Timer_PrepareTarget, dp, TIMER_FLAG_NO_MAPCHANGE);
		dp.WriteCell(GetClientUserId(target));
		dp.WriteCell(GetClientUserId(tank));
		PrintToAll("SpawnedFor", client, target);
	}
	else
		PrintToAll("Spawned", client);

	LogAction(client, target > 0 ? target : -1, "\"%L\" spawned a tank (%s)%s", client, here ? "crosshair" : "random spot", target > 0 ? " for target" : "");
	return Plugin_Handled;
}

int PickDefaultTarget(int admin)
{
	if (IsInGameClient(admin) && !IsFakeClient(admin) && GetClientTeam(admin) == TEAM_INFECTED)
		return admin;

	int[] candidates = new int[MaxClients];
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_INFECTED)
			candidates[count++] = i;
	}
	return count > 0 ? candidates[GetRandomInt(0, count - 1)] : 0;
}

// Step 1: the target must be dead to take over the tank bot (same as tank pass).
public Action Timer_PrepareTarget(Handle timer, DataPack dp)
{
	dp.Reset();
	int target = GetClientOfUserId(dp.ReadCell());
	int tankUserId = dp.ReadCell();
	if (target == 0 || !IsClientInGame(target) || GetClientTeam(target) != TEAM_INFECTED)
		return Plugin_Stop;

	if (IsPlayerAlive(target))
		ForcePlayerSuicide(target);

	DataPack dp2;
	CreateDataTimer(0.1, Timer_GiveTank, dp2, TIMER_FLAG_NO_MAPCHANGE);
	dp2.WriteCell(GetClientUserId(target));
	dp2.WriteCell(tankUserId);
	return Plugin_Stop;
}

// Step 2: hand the tank bot over to the target.
public Action Timer_GiveTank(Handle timer, DataPack dp)
{
	dp.Reset();
	int target = GetClientOfUserId(dp.ReadCell());
	int tank = GetClientOfUserId(dp.ReadCell());
	if (target == 0 || !IsClientInGame(target) || GetClientTeam(target) != TEAM_INFECTED)
		return Plugin_Stop;
	// The game may already have given the tank to someone else.
	if (tank == 0 || !IsFakeClient(tank) || !IsAliveTank(tank))
		return Plugin_Stop;

	L4D_TakeOverZombieBot(target, tank);
	return Plugin_Stop;
}

/*
 * ============================
 * Positions
 * ============================
 */

// Valid tank spawn spot near the leading survivor (same search the director uses).
bool GetSpawnSpot(float pos[3])
{
	int survivor = L4D_GetHighestFlowSurvivor();
	if (survivor <= 0 || !IsClientInGame(survivor))
	{
		survivor = 0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
			{
				survivor = i;
				break;
			}
		}
	}
	return L4D_GetRandomPZSpawnPosition(survivor, ZC_TANK, 30, pos);
}

// Ground spot on the navmesh closest to where the admin is aiming.
bool GetAimSpot(int client, float pos[3])
{
	float eye[3], ang[3], dir[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);

	Handle tr = TR_TraceRayFilterEx(eye, ang, MASK_SOLID, RayType_Infinite, TraceFilter_NoPlayers);
	if (!TR_DidHit(tr))
	{
		delete tr;
		return false;
	}
	TR_GetEndPosition(pos, tr);
	delete tr;

	// Step back a bit from the wall/ground that was hit.
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, 40.0);
	SubtractVectors(pos, dir, pos);

	Address nav = L4D_GetNearestNavArea(pos, 300.0, false, false, true, TEAM_INFECTED);
	if (nav == Address_Null)
		return false;
	L4D_FindRandomSpot(view_as<int>(nav), pos);
	return true;
}

public bool TraceFilter_NoPlayers(int entity, int contentsMask)
{
	return entity > MaxClients || entity == 0;
}

/*
 * ============================
 * Helpers
 * ============================
 */

bool IsInGameClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

bool IsAliveTank(int client)
{
	return IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED && IsPlayerAlive(client)
		&& GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK;
}

// Message to every human, each one in their own language.
void PrintToAll(const char[] phrase, int admin, int target = 0)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		if (target > 0)
			CPrintToChat(i, "%T %T", "Tag", i, phrase, i, admin, target);
		else
			CPrintToChat(i, "%T %T", "Tag", i, phrase, i, admin);
	}
}
