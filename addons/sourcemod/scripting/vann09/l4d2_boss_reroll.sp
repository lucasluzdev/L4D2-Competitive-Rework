#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <colors>
#undef REQUIRE_PLUGIN
#include <witch_and_tankifier>
#include <l4d2_boss_percents>

#define PLUGIN_VERSION "1.0"

/*
 * !reroll - re-draws the tank and witch flow % before survivors leave the saferoom.
 *
 * Uses witch_and_tankifier's own valid ranges (versus_boss_flow_min/max, the map's
 * tank_ban_flow / witch_ban_flow and sm_witch_avoid_tank_spawn), so a reroll follows
 * exactly the same rules as the round-start draw. The new values apply to both halves.
 */

public Plugin myinfo =
{
	name = "L4D2 Boss Reroll",
	author = "Vann09",
	description = "Admin command to re-draw tank/witch spawn percentages (uses witch_and_tankifier rules).",
	version = PLUGIN_VERSION
};

public void OnPluginStart()
{
	LoadTranslations("l4d2_boss_reroll.phrases");
	CreateConVar("l4d2_boss_reroll_version", PLUGIN_VERSION, "L4D2 Boss Reroll version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	RegAdminCmd("sm_reroll", Cmd_Reroll, ADMFLAG_GENERIC, "Re-draws tank and witch spawn percentages (before survivors leave the saferoom).");
}

public Action Cmd_Reroll(int client, int args)
{
	if (GetFeatureStatus(FeatureType_Native, "SetTankPercent") != FeatureStatus_Available)
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "NoTankifier", client);
		return Plugin_Handled;
	}
	if (GameRules_GetProp("m_bInSecondHalfOfRound"))
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "SecondHalf", client);
		return Plugin_Handled;
	}
	if (L4D_HasAnySurvivorLeftSafeArea())
	{
		CReplyToCommand(client, "%T %T", "Tag", client, "LeftSafeArea", client);
		return Plugin_Handled;
	}

	// Tank first: SetTankPercent also moves the witch's "avoid tank" window.
	int tank = 0;
	if (L4D2Direct_GetVSTankToSpawnThisRound(0) && !IsStaticTankMap())
	{
		tank = PickRandom(true);
		if (tank > 0)
			SetTankPercent(tank);
	}
	else
		tank = RoundToNearest(L4D2Direct_GetVSTankFlowPercent(0) * 100.0);

	int witch = 0;
	if (L4D2Direct_GetVSWitchToSpawnThisRound(0) && !IsStaticWitchMap())
	{
		witch = PickRandom(false);
		if (witch > 0)
			SetWitchPercent(witch);
	}
	else
		witch = RoundToNearest(L4D2Direct_GetVSWitchFlowPercent(0) * 100.0);

	// Refresh !boss and the readyup footer.
	if (GetFeatureStatus(FeatureType_Native, "UpdateBossPercents") == FeatureStatus_Available)
		UpdateBossPercents();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			CPrintToChat(i, "%T %T", "Tag", i, "Rerolled", i, client, tank, witch);
	}
	LogAction(client, -1, "\"%L\" rerolled boss spawns (tank %d%%, witch %d%%)", client, tank, witch);
	return Plugin_Handled;
}

// Random flow (1..100) that witch_and_tankifier considers valid right now; 0 if none.
int PickRandom(bool isTank)
{
	int valid[100], count = 0;
	for (int flow = 1; flow <= 100; flow++)
	{
		if (isTank ? IsTankPercentValid(flow) : IsWitchPercentValid(flow))
			valid[count++] = flow;
	}
	return count > 0 ? valid[GetRandomInt(0, count - 1)] : 0;
}
