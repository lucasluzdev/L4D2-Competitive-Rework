#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0"

public Plugin myinfo =
{
	name        = "Director Diagnostics",
	author      = "SafeRoom",
	description = "Dumps director/spawn cvars, teams and loaded plugins (sm_diag)",
	version     = PLUGIN_VERSION,
	url         = ""
};

// Section headers start with '#'. Hidden (dev-only) cvars work too, since FindConVar sees them.
static const char g_sCvars[][] =
{
	"#match / mode",
	"mp_gamemode", "z_difficulty", "sv_cheats", "sb_all_bot_game", "sb_stop", "god",
	"l4d_ready_enabled", "l4d_ready_cfg_name", "confogl_match_execcfg_on", "stripper_cfg_path",

	"#commons / hordes",
	"z_common_limit", "z_background_limit", "z_mob_population_density", "z_wandering_density",
	"z_mob_spawn_min_size", "z_mob_spawn_max_size", "z_mob_spawn_finale_size", "z_mega_mob_size",
	"z_mob_spawn_min_interval_normal", "z_mob_spawn_max_interval_normal",
	"director_no_mobs", "director_panic_forever",

	"#special infected",
	"director_no_specials", "director_no_bosses", "director_allow_infected_bots",
	"z_max_player_zombies", "survivor_limit", "z_ghost_delay_min", "z_ghost_delay_max",
	"versus_special_respawn_interval",
	"z_versus_smoker_limit", "z_versus_boomer_limit", "z_versus_hunter_limit",
	"z_versus_spitter_limit", "z_versus_jockey_limit", "z_versus_charger_limit",

	"#AI update budget",
	"nb_update_frequency", "nb_update_framelimit", "fps_max"
};

char g_sLogPath[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/diag_director.log");
	RegAdminCmd("sm_diag", Cmd_Diag, ADMFLAG_CONFIG, "Dump director/spawn state to reply and addons/sourcemod/logs/diag_director.log");
}

// Sends a line to whoever ran the command (works through rcon) and appends it to the log file.
void Out(int client, const char[] format, any ...)
{
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);
	ReplyToCommand(client, "%s", buffer);
	LogToFileEx(g_sLogPath, "%s", buffer);
}

Action Cmd_Diag(int client, int args)
{
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	Out(client, "===== DIAG: start (map %s, uptime %.0fs) =====", map, GetEngineTime());

	// Humans / bots per team: 1 = spectator, 2 = survivor, 3 = infected.
	int humans[4], bots[4];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		int team = GetClientTeam(i);
		if (team < 0 || team > 3) continue;
		if (IsFakeClient(i)) bots[team]++; else humans[team]++;
	}
	Out(client, "teams: survivors %d human / %d bot | infected %d human / %d bot | spectators %d",
		humans[2], bots[2], humans[3], bots[3], humans[1]);

	char value[256];
	for (int i = 0; i < sizeof(g_sCvars); i++)
	{
		if (g_sCvars[i][0] == '#')
		{
			Out(client, "----- %s -----", g_sCvars[i][1]);
			continue;
		}

		ConVar cvar = FindConVar(g_sCvars[i]);
		if (cvar == null)
		{
			Out(client, "%s = <not found>", g_sCvars[i]);
			continue;
		}
		cvar.GetString(value, sizeof(value));
		Out(client, "%s = \"%s\"", g_sCvars[i], value);
	}

	Out(client, "----- plugins -----");
	char file[PLATFORM_MAX_PATH], status[16];
	Handle iter = GetPluginIterator();
	while (MorePlugins(iter))
	{
		Handle plugin = ReadPlugin(iter);
		GetPluginFilename(plugin, file, sizeof(file));
		status = (GetPluginStatus(plugin) == Plugin_Running) ? "running" : "NOT RUNNING";
		Out(client, "%s (%s)", file, status);
	}
	delete iter;

	Out(client, "===== DIAG: end =====");
	return Plugin_Handled;
}
