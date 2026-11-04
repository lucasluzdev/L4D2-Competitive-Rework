#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>

char mapName[64];

bool tankIsAlive = false;
bool witchIsAlive = false;

// =====================================================
// FLOW STORAGE
// =====================================================

int g_iTankPercent = -1;
int g_iWitchPercent = -1;

Handle g_hVsBossBuffer;

// =====================================================
// RANDOMIZATION SETTINGS
// =====================================================

const int minWitchPercent = 15;
const int maxWitchPercent = 86;

const int minTankPercent = 10;
const int maxTankPercent = 86;

const int minGapPercent = 15;
const int maxGapPercent = 40;

// =====================================================
// MAPS SEM TANK
// =====================================================

char restrictedTankMaps[][32] =
{
	//"c8m1_apartment",
	"c5m5_bridge",
	"c7m1_docks",
	"c7m3_port",
	"c6m3_port",
	"c4m5_milltown_escape",
	"c13m2_southpinestream",
	"c8m5_rooftop",
	"c11m5_runway",
};

// =====================================================
// MAPS SEM WITCH
// =====================================================

char restrictedWitchMaps[][32] =
{
	"c1m4_atrium",
	"c6m1_riverbank",
	"c6m3_port",
	"c7m3_port",
	"c11m5_runway",
	"c8m5_rooftop",
	"c5m5_bridge",
	"c4m5_milltown_escape"
};

// =====================================================
// MULTI BLOCK RULES
// =====================================================

enum struct BossBlockRule
{
	char map[32];
	int minPercent;
	int maxPercent;
}

// =====================================================
// TANK BLOCKS
// =====================================================

BossBlockRule g_TankBlockRules[] =
{
	{ "c1m1_hotel", 0, 60 },

	{ "c1m1_hotel", 75, 100 },

	{ "c1m3_mall", 60, 100 },

	{ "c2m2_fairgrounds", 70, 100 },

	{ "c2m3_coaster", 0, 20 },

	{ "c2m3_coaster", 48, 75 },

	{ "c2m4_barns", 0, 20 },

	{ "c2m4_barns", 75, 100 },

	{ "c4m2_sugarmill_a", 60, 100 },

	{ "c4m3_sugarmill_b", 0, 30 },

	{ "c4m3_sugarmill_b", 75, 100 },

	{ "c5m1_waterfront", 60, 100 },

	{ "c5m2_park", 75, 100 },

	{ "c5m3_cemetery", 50, 70 },

	{ "c5m4_quarter", 70, 100 },

	{ "c6m2_bedlam", 60, 100 },

	{ "c7m2_barge", 70, 100 },

	{ "c8m1_apartment", 0, 65 },

	{ "c8m1_apartment", 79, 100 },

	{ "c8m2_subway", 60, 100 },

	{ "c8m3_sewers", 0, 30 },

	{ "c8m3_sewers", 80, 100 },

	{ "c8m4_interior", 0, 18 },

	{ "c8m4_interior", 28, 70 },

	{ "c8m4_interior", 80, 100 },

	{ "c10m1_caves", 0, 20 },

	{ "c10m1_caves", 50, 100 },

	{ "c10m2_drainage", 70, 100 },

	{ "c10m3_ranchhouse", 75, 100 },

	{ "c10m4_mainstreet", 70, 100 },

	{ "c11m1_greenhouse", 0, 20 },

	{ "c11m1_greenhouse", 50, 100 },

	{ "c11m2_offices", 0, 40 },

	{ "c11m2_offices", 80, 100 },

	{ "c11m3_garage", 0, 30 },

	{ "c11m3_garage", 75, 100 },

	{ "c11m4_terminal", 30, 50 },

	{ "c11m4_terminal", 60, 100 }
};

// =====================================================
// WITCH BLOCKS
// =====================================================

BossBlockRule g_WitchBlockRules[] =
{
	{ "c1m1_hotel", 0, 60 },
	{ "c8m4_interior", 35, 70 },
	{ "c10m4_mainstreet", 70, 100 },
	{ "c11m4_terminal", 70, 100 }
};

public Plugin myinfo =
{
	name = "Boss Spawn Control",
	author = "pa4H, Vann09",
	description = "Boss spawn controller with reroll and flow restrictions",
	version = "1.2-fixed",
	url = ""
};

public void OnPluginStart()
{
	RegConsoleCmd("sm_boss", Command_BossFlow);
	RegConsoleCmd("sm_tank", Command_TankFlow);

	RegAdminCmd("sm_reroll", Command_Reroll, ADMFLAG_GENERIC);

	HookEvent("round_start", RoundStartEvent, EventHookMode_PostNoCopy);

	HookEvent("tank_spawn", TankNotify, EventHookMode_PostNoCopy);
	HookEvent("witch_spawn", WitchNotify, EventHookMode_PostNoCopy);

	HookEvent("player_death", TankDead, EventHookMode_Pre);

	g_hVsBossBuffer = FindConVar("versus_boss_buffer");

	LoadTranslations("l4d2_boss_spawn_control.phrases");
}

public void RoundStartEvent(Event event, const char[] name, bool dontBroadcast)
{
	tankIsAlive = false;
	witchIsAlive = false;

	GetCurrentMap(mapName, sizeof(mapName));

	// =====================================================
	// FIRST HALF
	// GENERATE FLOWS ONLY ONCE
	// =====================================================

	if (GameRules_GetProp("m_bInSecondHalfOfRound") == 0)
	{
		CreateTimer(0.4, AdjustBossFlow_FirstHalf);
	}
	else
	{
		// =====================================================
		// SECOND HALF
		// REAPPLY SAME FLOWS
		// =====================================================

		CreateTimer(0.4, AdjustBossFlow_SecondHalf);
	}
}

// =====================================================
// FIRST HALF
// =====================================================

public Action AdjustBossFlow_FirstHalf(Handle timer)
{
	SetupBosses();

	if (L4D_IsMissionFinalMap())
	{
		g_iTankPercent = 10;
		g_iWitchPercent = 15;
	}
	else
	{
		GenerateRandomBossFlows();
	}

	ApplyBossFlows();

	return Plugin_Stop;
}

// =====================================================
// SECOND HALF
// =====================================================

public Action AdjustBossFlow_SecondHalf(Handle timer)
{
	SetupBosses();

	// =====================================================
	// IMPORTANT:
	// DO NOT REROLL HERE
	// ONLY REAPPLY SAVED VALUES
	// =====================================================

	ApplyBossFlows();

	return Plugin_Stop;
}

// =====================================================
// ENABLE/DISABLE BOSSES
// =====================================================

void SetupBosses()
{
	bool allowTank = true;
	bool allowWitch = true;

	for (int i = 0; i < sizeof(restrictedTankMaps); i++)
	{
		if (StrEqual(restrictedTankMaps[i], mapName))
		{
			allowTank = false;
			break;
		}
	}

	for (int i = 0; i < sizeof(restrictedWitchMaps); i++)
	{
		if (StrEqual(restrictedWitchMaps[i], mapName))
		{
			allowWitch = false;
			break;
		}
	}

	L4D2Direct_SetVSTankToSpawnThisRound(0, allowTank);
	L4D2Direct_SetVSTankToSpawnThisRound(1, allowTank);

	L4D2Direct_SetVSWitchToSpawnThisRound(0, allowWitch);
	L4D2Direct_SetVSWitchToSpawnThisRound(1, allowWitch);
}

// =====================================================
// GENERATE RANDOM FLOWS
// =====================================================

void GenerateRandomBossFlows()
{
	int attempts = 0;

	do
	{
		int gapPercent = GetRandomInt(minGapPercent, maxGapPercent);

		bool tankFirst = GetRandomInt(0, 1) == 1;

		if (tankFirst)
		{
			g_iTankPercent = GetRandomInt(
				minTankPercent,
				maxTankPercent - gapPercent
			);

			g_iWitchPercent = g_iTankPercent + gapPercent;
		}
		else
		{
			g_iWitchPercent = GetRandomInt(
				minWitchPercent,
				maxWitchPercent - gapPercent
			);

			g_iTankPercent = g_iWitchPercent + gapPercent;
		}

		attempts++;

	}
	while (
		(
			g_iTankPercent > maxTankPercent ||
			g_iWitchPercent > maxWitchPercent ||

			g_iTankPercent < minTankPercent ||
			g_iWitchPercent < minWitchPercent ||

			IsTankFlowBlocked(mapName, g_iTankPercent) ||
			IsWitchFlowBlocked(mapName, g_iWitchPercent)
		)
		&& attempts < 200
	);

	// =====================================================
	// FALLBACK
	// =====================================================

	if (attempts >= 200)
	{
		g_iTankPercent = 60;
		g_iWitchPercent = 30;
	}
}

// =====================================================
// APPLY FLOWS
// =====================================================

void ApplyBossFlows()
{
	float tankFlow = CalcFlow(g_iTankPercent);
	float witchFlow = CalcFlow(g_iWitchPercent);

	L4D2Direct_SetVSTankFlowPercent(0, tankFlow);
	L4D2Direct_SetVSTankFlowPercent(1, tankFlow);

	L4D2Direct_SetVSWitchFlowPercent(0, witchFlow);
	L4D2Direct_SetVSWitchFlowPercent(1, witchFlow);
}

// =====================================================
// !REROLL
// =====================================================

public Action Command_Reroll(int client, int args)
{
	if (L4D_HasAnySurvivorLeftSafeArea())
	{
		CPrintToChat(client, "%t", "BossRerollBlocked");
		return Plugin_Handled;
	}

	GenerateRandomBossFlows();
	ApplyBossFlows();

	CPrintToChatAll(
		"%t",
		"BossRerolled",
		g_iTankPercent,
		g_iWitchPercent
	);

	return Plugin_Handled;
}

// =====================================================
// !BOSS
// =====================================================

public Action Command_BossFlow(int client, int args)
{
	ShowBossPercents(client);
	return Plugin_Handled;
}

// =====================================================
// !TANK
// =====================================================

public Action Command_TankFlow(int client, int args)
{
	ShowBossPercents(client);
	return Plugin_Handled;
}

// =====================================================
// DISPLAY BOSS INFO
// =====================================================

void ShowBossPercents(int client)
{
	if (client <= 0 || !IsClientInGame(client))
	{
		return;
	}

	bool tankEnabled =
		L4D2Direct_GetVSTankToSpawnThisRound(0) ||
		L4D2Direct_GetVSTankToSpawnThisRound(1);

	bool witchEnabled =
		L4D2Direct_GetVSWitchToSpawnThisRound(0) ||
		L4D2Direct_GetVSWitchToSpawnThisRound(1);

	float survivorFlow = GetSurvivorMaxFlowPercent();

	CPrintToChat(
		client,
		"%t",
		"BossSurvivorFlow",
		RoundToNearest(survivorFlow)
	);

	if (tankEnabled)
	{
		CPrintToChat(
			client,
			"%t",
			"BossTankSpawn",
			g_iTankPercent
		);
	}
	else
	{
		CPrintToChat(
			client,
			"%t",
			"BossTankNone"
		);
	}

	if (witchEnabled)
	{
		CPrintToChat(
			client,
			"%t",
			"BossWitchSpawn",
			g_iWitchPercent
		);
	}
	else
	{
		CPrintToChat(
			client,
			"%t",
			"BossWitchNone"
		);
	}
}

// =====================================================
// GET SURVIVOR MAX FLOW
// =====================================================

float GetSurvivorMaxFlowPercent()
{
	float bestFlow = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (
			IsClientInGame(i) &&
			GetClientTeam(i) == 2 &&
			IsPlayerAlive(i)
		)
		{
			float flow = L4D2Direct_GetFlowDistance(i);

			if (flow > bestFlow)
			{
				bestFlow = flow;
			}
		}
	}

	return (
		bestFlow /
		L4D2Direct_GetMapMaxFlowDistance()
	) * 100.0;
}

// =====================================================
// BLOCK RULES
// =====================================================

bool IsTankFlowBlocked(const char[] currentMap, int percent)
{
	for (int i = 0; i < sizeof(g_TankBlockRules); i++)
	{
		if (StrEqual(g_TankBlockRules[i].map, currentMap))
		{
			if (
				percent >= g_TankBlockRules[i].minPercent &&
				percent <= g_TankBlockRules[i].maxPercent
			)
			{
				return true;
			}
		}
	}

	return false;
}

bool IsWitchFlowBlocked(const char[] currentMap, int percent)
{
	for (int i = 0; i < sizeof(g_WitchBlockRules); i++)
	{
		if (StrEqual(g_WitchBlockRules[i].map, currentMap))
		{
			if (
				percent >= g_WitchBlockRules[i].minPercent &&
				percent <= g_WitchBlockRules[i].maxPercent
			)
			{
				return true;
			}
		}
	}

	return false;
}

// =====================================================
// TANK NOTIFY
// =====================================================

public void TankNotify(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!tankIsAlive)
	{
		tankIsAlive = true;

		PrecacheSound("ui/pickup_secret01.wav");
		EmitSoundToAll("ui/pickup_secret01.wav");

		if (IsFakeClient(client))
		{
			CPrintToChatAll("%t", "TankIsHereBOT");
		}
		else
		{
			for (int i = 1; i <= MaxClients; i++)
			{
				if (IsValidClient(i))
				{
					if (i == client)
					{
						CPrintToChat(i, "%t", "PassTankNotify");
					}
					else
					{
						CPrintToChat(i, "%t", "TankIsHere", client);
					}
				}
			}
		}
	}
}

// =====================================================
// WITCH NOTIFY
// =====================================================

public void WitchNotify(Event event, const char[] name, bool dontBroadcast)
{
	if (!witchIsAlive)
	{
		witchIsAlive = true;

		PrecacheSound("ui/beepclear.wav");
		EmitSoundToAll("ui/beepclear.wav");

		CPrintToChatAll(
			"%t",
			"WitchIsHere",
			g_iWitchPercent
		);
	}
}

// =====================================================
// RESET FLAGS
// =====================================================

public void TankDead(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));

	if (victim != 0 && GetClientTeam(victim) == L4D_TEAM_INFECTED)
	{
		int zClass = GetEntProp(victim, Prop_Send, "m_zombieClass");

		if (zClass == 8)
		{
			tankIsAlive = false;
		}

		if (zClass == 7)
		{
			witchIsAlive = false;
		}
	}
}

// =====================================================
// FLOW UTILS
// =====================================================

float CalcFlow(int per)
{
	return ((float(per) + 0.01) / 100.0)
		+ GetConVarFloat(g_hVsBossBuffer)
		/ L4D2Direct_GetMapMaxFlowDistance();
}

// =====================================================
// VALID CLIENT
// =====================================================

stock bool IsValidClient(int client)
{
	if (
		client > 0 &&
		client <= MaxClients &&
		IsClientInGame(client) &&
		IsClientConnected(client) &&
		!IsFakeClient(client)
	)
	{
		return true;
	}

	return false;
}

// =====================================================
// DIRECTOR OVERRIDES
// =====================================================

public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{
	int val = retVal;

	if (StrEqual(key, "ProhibitBosses"))
	{
		val = 0;
	}

	if (StrEqual(key, "DisallowThreatType"))
	{
		val = 0;
	}

	if (StrEqual(key, "TankLimit"))
	{
		val = 1;
	}

	if (StrEqual(key, "WitchLimit"))
	{
		val = 1;
	}

	if (val != retVal)
	{
		retVal = val;
		return Plugin_Handled;
	}

	return Plugin_Continue;
}