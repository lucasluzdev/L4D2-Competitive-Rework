/*
 * L4D2 Tank HP Debug
 *
 * Ferramenta de teste: mostra a vida do tank e o dano de cada golpe (hint na tela).
 * - !tankhp (admin): liga/desliga so para quem usou o comando (qualquer time).
 * - l4d2_tankhp_survivors 1: mostra para todos os sobreviventes (sessoes de teste).
 * Desligado por padrao: em partida normal ninguem ve nada.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define TEAM_SURVIVOR 2
#define ZC_TANK 8

public Plugin myinfo =
{
	name = "L4D2 Tank HP Debug",
	author = "vann09",
	description = "Shows tank health and per-hit damage for testing.",
	version = "1.0",
	url = ""
};

ConVar g_hCvarSurvivors;
bool g_bEnabled[MAXPLAYERS + 1];

public void OnPluginStart()
{
	g_hCvarSurvivors = CreateConVar("l4d2_tankhp_survivors", "0",
		"Show tank HP and per-hit damage to all survivors (testing only).", _, true, 0.0, true, 1.0);

	RegAdminCmd("sm_tankhp", Cmd_TankHp, ADMFLAG_GENERIC, "Toggle tank HP / damage display for yourself.");

	HookEvent("player_hurt", Event_PlayerHurt);
}

public void OnClientDisconnect(int client)
{
	g_bEnabled[client] = false;
}

Action Cmd_TankHp(int client, int args)
{
	if (client == 0) {
		ReplyToCommand(client, "[TankHP] In-game only. Use l4d2_tankhp_survivors 1 for all survivors.");
		return Plugin_Handled;
	}

	g_bEnabled[client] = !g_bEnabled[client];
	ReplyToCommand(client, "[TankHP] %s", g_bEnabled[client] ? "ON" : "OFF");
	return Plugin_Handled;
}

void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0 || !IsClientInGame(victim) || GetClientTeam(victim) != 3
		|| GetEntProp(victim, Prop_Send, "m_zombieClass") != ZC_TANK) {
		return;
	}

	int damage = event.GetInt("dmg_health");
	int health = event.GetInt("health");
	if (health < 0) health = 0;
	int maxHealth = GetEntProp(victim, Prop_Data, "m_iMaxHealth");

	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));

	char attackerName[MAX_NAME_LENGTH] = "?";
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker > 0 && IsClientInGame(attacker)) {
		GetClientName(attacker, attackerName, sizeof(attackerName));
	}

	bool toSurvivors = g_hCvarSurvivors.BoolValue;
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsFakeClient(i)) continue;
		if (!g_bEnabled[i] && !(toSurvivors && GetClientTeam(i) == TEAM_SURVIVOR)) continue;

		PrintHintText(i, "Tank HP: %d / %d\n-%d (%s) por %s", health, maxHealth, damage, weapon, attackerName);
	}
}
