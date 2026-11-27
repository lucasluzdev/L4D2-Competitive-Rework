#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <colors>

#define PLUGIN_VERSION "1.4.1"

#define TEAM_SPECTATOR 1
#define TEAM_INFECTED  3
#define ZC_TANK        8

/*
 * Tank frustration refill (same idea as ZoneMod's l4d_tank_control_eq, without its tank selection):
 *   - 1st time the frustration bar empties: the bar is refilled and the same player keeps the Tank.
 *   - 2nd time: the Tank goes to the AI, as usual.
 *
 * The refill belongs to the Tank, not to the player:
 *   - passed with !passtank (l4d_tank_pass) BEFORE the refill -> the new player still has the refill;
 *   - passed AFTER the refill -> the new player's empty bar sends the Tank to the AI.
 *
 * How: the game's "tank passed count" decides what an empty bar does (1 = offer the Tank, 2 = AI).
 * l4d_tank_pass rewrites that count on every pass, so while a Tank is alive this plugin keeps it at
 * 1 (refill still available) or 2 (refill used). The refill itself happens in L4D_OnTryOfferingTankBot,
 * except for offers made by l4d_tank_pass itself (finale passes, detected by its 10000 tank tickets).
 */

public Plugin myinfo =
{
	name = "L4D2 Tank Frustration Refill",
	author = "Vann09",
	description = "Refills the Tank's frustration once instead of passing it; the second time it goes to the AI.",
	version = PLUGIN_VERSION
};

ConVar g_hCvarEnable, g_hCvarThreshold, g_hCvarDebug, g_hCvarLifetime;
bool g_bTankInPlay;		// a Tank is alive (one "Tank life" lasts across passes)
bool g_bRefillUsed;		// this Tank life already got its refill
float g_fNoTankSince;	// when the last alive Tank disappeared (hand-offs leave a short gap)
int g_iDebugTick;
Handle g_hWatchTimer;

#define NO_TANK_GRACE 2.0	// seconds without any alive Tank before the Tank life ends

public void OnPluginStart()
{
	LoadTranslations("l4d2_tank_refill.phrases");
	CreateConVar("l4d2_tank_refill_version", PLUGIN_VERSION, "L4D2 Tank Frustration Refill version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_hCvarEnable = CreateConVar("l4d2_tank_refill", "1", "Refill the Tank's frustration once instead of passing it to another player", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_hCvarThreshold = CreateConVar("l4d2_tank_refill_threshold", "0", "Refill when the frustration (m_frustration, 0 = full bar, 100 = empty) reaches this value. 0 = auto: the last step before the bar empties", FCVAR_NOTIFY, true, 0.0, true, 99.0);
	g_hCvarLifetime = FindConVar("z_frustration_lifetime");

	g_hCvarDebug = CreateConVar("l4d2_tank_refill_debug", "0", "Log the Tank's frustration every second (diagnostics)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	// Always start here too: confogl loads its plugins mid-map (often while the server hibernates),
	// and OnMapStart won't run again for that map.
	StartWatch();
}

public void OnMapStart()
{
	StartWatch();
}

public void OnMapEnd()
{
	g_hWatchTimer = null; // killed by TIMER_FLAG_NO_MAPCHANGE
}

// One timer for the whole map: it doesn't depend on tank_spawn, which doesn't fire when a player
// takes over a Tank bot (!spawntank, !taketank).
void StartWatch()
{
	ResetTankLife();
	if (g_hWatchTimer != null)
		return;
	g_hWatchTimer = CreateTimer(0.1, Timer_Watch, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	if (g_hCvarDebug.BoolValue)
		LogMessage("[Refill] Debug: watch timer started");
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetTankLife();
}

void ResetTankLife()
{
	g_bTankInPlay = false;
	g_bRefillUsed = false;
	g_fNoTankSince = 0.0;
}

// Tracks the Tank life, refills just before the bar runs out and keeps the game's pass count in line.
Action Timer_Watch(Handle timer)
{
	int tank = FindAliveTank();
	if (tank == -1)
	{
		if (g_bTankInPlay)
		{
			if (g_fNoTankSince == 0.0)
				g_fNoTankSince = GetGameTime();
			else if (GetGameTime() - g_fNoTankSince > NO_TANK_GRACE)
			{
				if (g_hCvarDebug.BoolValue)
					LogMessage("[Refill] Debug: tank life ended (refillUsed=%d)", g_bRefillUsed);
				ResetTankLife();
			}
		}
		return Plugin_Continue;
	}

	g_fNoTankSince = 0.0;
	if (!g_bTankInPlay)
	{
		g_bTankInPlay = true;
		g_bRefillUsed = false;
		if (g_hCvarDebug.BoolValue)
			LogMessage("[Refill] Debug: new tank life, tank=%L fake=%d", tank, IsFakeClient(tank));
	}

	if (g_hCvarDebug.BoolValue && ++g_iDebugTick >= 10)
	{
		g_iDebugTick = 0;
		LogMessage("[Refill] Debug: tank=%L fake=%d frustration=%d passcount=%d refillUsed=%d",
			tank, IsFakeClient(tank), GetEntProp(tank, Prop_Send, "m_frustration"), L4D2Direct_GetTankPassedCount(), g_bRefillUsed);
	}

	if (g_hCvarEnable.BoolValue && !IsFakeClient(tank))
	{
		// Refill just before the bar runs out. When nobody else can take the Tank, the game sends it
		// straight to the AI without offering it, so waiting for L4D_OnTryOfferingTankBot isn't enough.
		if (!g_bRefillUsed && GetEntProp(tank, Prop_Send, "m_frustration") >= GetRefillThreshold())
			DoRefill(tank);

		int want = g_bRefillUsed ? 2 : 1;
		if (L4D2Direct_GetTankPassedCount() != want)
			L4D2Direct_SetTankPassedCount(want);
	}
	return Plugin_Continue;
}

public Action L4D_OnTryOfferingTankBot(int tank_index, bool &enterStasis)
{
	if (!g_hCvarEnable.BoolValue || tank_index <= 0 || tank_index > MaxClients || !IsClientInGame(tank_index))
		return Plugin_Continue;

	// Tank spawning (AI bot being offered) -> nothing to do.
	if (IsFakeClient(tank_index))
	{
		if (g_bTankInPlay && g_hCvarDebug.BoolValue)
			LogMessage("[Refill] Offer of AI tank %L (passcount=%d refillUsed=%d)", tank_index, L4D2Direct_GetTankPassedCount(), g_bRefillUsed);
		return Plugin_Continue;
	}

	// The game resets m_frustration before offering, so the bar can't tell a frustration pass apart.
	// l4d_tank_pass (finale / non-quick pass) marks its target with 10000 tank tickets right before
	// offering: that offer is a voluntary pass, leave it alone.
	bool bPluginPass = IsTankPassOffer(tank_index);
	if (g_hCvarDebug.BoolValue)
		LogMessage("[Refill] Offer: tank=%L frustration=%d passcount=%d refillUsed=%d tankPassOffer=%d",
		tank_index, GetEntProp(tank_index, Prop_Send, "m_frustration"), L4D2Direct_GetTankPassedCount(), g_bRefillUsed, bPluginPass);
	if (bPluginPass)
		return Plugin_Continue;

	if (g_bRefillUsed)
	{
		// Already refilled: let the game go to the AI. Pass count 2 makes the game skip the offer.
		L4D2Direct_SetTankPassedCount(2);
		return Plugin_Continue;
	}

	DoRefill(tank_index);
	return Plugin_Handled;
}

void DoRefill(int tank)
{
	g_bRefillUsed = true;
	SetEntProp(tank, Prop_Send, "m_frustration", 0);
	L4D2Direct_SetTankPassedCount(2);
	LogMessage("[Refill] Refilled %L", tank);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		int team = GetClientTeam(i);
		if (team != TEAM_INFECTED && team != TEAM_SPECTATOR)
			continue;

		if (i == tank)
			CPrintToChat(i, "%T %T", "Tag", i, "RefilledSelf", i);
		else
			CPrintToChat(i, "%T %T", "Tag", i, "Refilled", i, tank);
	}
}

// m_frustration grows in steps of 100 / z_frustration_lifetime per second (lifetime 20 -> 0,5,...,95,100)
// and the Tank is passed on the same frame it hits 100, so the refill must happen on the last step
// before that (95 with lifetime 20, 80 with lifetime 5).
int GetRefillThreshold()
{
	int fixed = g_hCvarThreshold.IntValue;
	if (fixed > 0)
		return fixed;

	float lifetime = (g_hCvarLifetime != null) ? g_hCvarLifetime.FloatValue : 20.0;
	if (lifetime < 1.0)
		lifetime = 1.0;
	int step = RoundToCeil(100.0 / lifetime);
	int threshold = 100 - step;
	return threshold < 1 ? 1 : threshold;
}

bool IsTankPassOffer(int tank)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != tank && IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && !IsFakeClient(i)
			&& L4D2Direct_GetTankTickets(i) == 10000)
			return true;
	}
	return false;
}

bool IsTankClient(int client)
{
	return IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED
		&& GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK;
}

int FindAliveTank()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsTankClient(i) && IsPlayerAlive(i) && !GetEntProp(i, Prop_Send, "m_isIncapacitated"))
			return i;
	}
	return -1;
}
