#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>

#define STEAMID_SIZE 32

#define L4D_TEAM_SPECTATE 1
#define L4D_TEAM_SURVIVORS 2

StringMap
    ArrLerpsValue = null,
    ArrLerpsCountChanges = null;

ConVar
    cVarReadyUpLerpChanges = null,
    cVarAllowedLerpChanges = null,
    cVarLerpChangeSpec = null,
    cVarBadLerpAction = null,
    cVarMinLerp = null,
    cVarMaxLerp = null,
    cVarMinUpdateRate = null,
    cVarMaxUpdateRate = null,
    cVarMinInterpRatio = null,
    cVarMaxInterpRatio = null,
    cVarShowLerpTeamChange = null;

bool
    IsLateLoad = false,
    isFirstHalf = true,
    isMatchLife = true,
    isTransfer = false;

float g_fLastLerpWarning[MAXPLAYERS + 1];

// The initial 0/0 client settings are accepted once, as the engine/server
// clamps them to the configured minimum lerp. Any subsequent settings change
// ends this exemption for the remainder of the connection.
bool g_bLerpInitialized[MAXPLAYERS + 1];
bool g_bInitialZeroLerp[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "LerpMonitor++",
    author = "ProdigySim, Die Teetasse, vintik, A1m`",
    description = "Keep track of players' lerp settings and suggest corrections",
    version = "2.4.4",
    url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    IsLateLoad = late;

    CreateNative("LM_GetLerpTime", LM_GetLerpTime);
    CreateNative("LM_GetCurrentLerpTime", LM_GetCurrentLerpTime);
    CreateNative("LM_GetStoredLerpTime", LM_GetStoredLerpTime);

    RegPluginLibrary("lerpmonitor");
    return APLRes_Success;
}

public void OnPluginStart()
{
    cVarAllowedLerpChanges = CreateConVar("sm_allowed_lerp_changes", "4", "Allowed number of lerp changes for a half", _, true, 0.0, true, 20.0);
    cVarLerpChangeSpec = CreateConVar("sm_lerp_change_spec", "1", "Move to spectators on exceeding lerp changes count?", _, true, 0.0, true, 1.0);
    cVarBadLerpAction = CreateConVar("sm_bad_lerp_action", "1", "What to do with a player if he is out of allowed lerp range? 1 - move to spectators, 0 - kick from server", _, true, 0.0, true, 1.0);
    cVarReadyUpLerpChanges = CreateConVar("sm_readyup_lerp_changes", "1", "Allow lerp changes during ready-up", _, true, 0.0, true, 1.0);
    cVarShowLerpTeamChange = CreateConVar("sm_show_lerp_team_changes", "1", "Show a message about the player's lerp if he changes the team", _, true, 0.0, true, 1.0);
    cVarMinLerp = CreateConVar(
		"sm_min_lerp", "0.01",
		"Minimum allowed lerp value",
		_, true, 0.01, true, 0.15
	);

    cVarMaxLerp = CreateConVar(
		"sm_max_lerp", "0.15",
		"Maximum allowed lerp value",
		_, true, 0.01, true, 0.15
	);

    RegConsoleCmd("sm_lerps", Lerps_Cmd, "List the Lerps of all players in game");

    cVarMinUpdateRate = FindConVar("sv_minupdaterate");
    cVarMaxUpdateRate = FindConVar("sv_maxupdaterate");
    cVarMinInterpRatio = FindConVar("sv_client_min_interp_ratio");
    cVarMaxInterpRatio = FindConVar("sv_client_max_interp_ratio");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("player_team", OnTeamChange, EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
    HookEvent("player_left_start_area", Event_RoundGoesLive, EventHookMode_PostNoCopy);

    ArrLerpsValue = new StringMap();
    ArrLerpsCountChanges = new StringMap();

    LateLoad();
}

void LateLoad()
{
    if (!IsLateLoad)
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        ProcessPlayerLerp(i, true);
    }
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client))
    {
        CreateTimer(1.0, Process, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

Action Process(Handle hTimer, int userid)
{
    int client = GetClientOfUserId(userid);

    if (client > 0)
    {
        ProcessPlayerLerp(client);
    }

    return Plugin_Stop;
}

public void OnMapStart()
{
    isMatchLife = false;
}

public void OnMapEnd()
{
    isFirstHalf = true;

    ArrLerpsValue.Clear();
    ArrLerpsCountChanges.Clear();

    for (int i = 1; i <= MaxClients; i++)
    {
        g_fLastLerpWarning[i] = 0.0;
    }
}

void Event_RoundGoesLive(Event hEvent, const char[] name, bool dontBroadcast)
{
    isMatchLife = true;
}

public void OnClientSettingsChanged(int client)
{
    if (IsValidEdict(client) && !IsFakeClient(client))
    {
        ProcessPlayerLerp(client);
    }
}

public void OnClientDisconnect(int client)
{
    g_bLerpInitialized[client] = false;
    g_bInitialZeroLerp[client] = false;
    g_fLastLerpWarning[client] = 0.0;
}

void Event_PlayerDisconnect(Event hEvent, const char[] name, bool dontBroadcast)
{
    char SteamID[64];
    hEvent.GetString("networkid", SteamID, sizeof(SteamID));

    if (StrContains(SteamID, "STEAM") != 0)
    {
        return;
    }

    ArrLerpsValue.Remove(SteamID);
    //ArrLerpsCountChanges.Remove(SteamID);
}

void OnTeamChange(Event hEvent, const char[] eName, bool dontBroadcast)
{
    if (hEvent.GetInt("team") > L4D_TEAM_SPECTATE)
    {
        int userid = hEvent.GetInt("userid");
        int client = GetClientOfUserId(userid);

        if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
        {
            if (!isTransfer)
            {
                CreateTimer(0.1, OnTeamChangeDelay, userid, TIMER_FLAG_NO_MAPCHANGE);
            }
        }
    }
}

Action OnTeamChangeDelay(Handle hTimer, int userid)
{
    int client = GetClientOfUserId(userid);

    if (client > 0)
    {
        ProcessPlayerLerp(client, false, true);
    }

    return Plugin_Stop;
}

void Event_RoundStart(Event hEvent, const char[] name, bool dontBroadcast)
{
    // Delete change count for the second half.
    if (!isFirstHalf)
    {
        ArrLerpsCountChanges.Clear();
    }

    CreateTimer(0.5, OnTransfer, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action OnTransfer(Handle hTimer)
{
    isTransfer = false;

    return Plugin_Stop;
}

void Event_RoundEnd(Event hEvent, const char[] name, bool dontBroadcast)
{
    CreateTimer(0.5, Timer_RoundEndDelay, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_RoundEndDelay(Handle hTimer)
{
    isFirstHalf = false;
    isTransfer = true;
    isMatchLife = false;

    ArrLerpsCountChanges.Clear();

    return Plugin_Stop;
}

void ProcessPlayerLerp(int client, bool load = false, bool team = false)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    // Detect and accept the client's initial 0/0 interp settings once.
    // If the client changes either value later, this exemption is revoked.
    if (!g_bLerpInitialized[client])
    {
        g_bLerpInitialized[client] = true;
        g_bInitialZeroLerp[client] = IsInitialZeroLerp(client);
    }
    else if (g_bInitialZeroLerp[client] && !IsInitialZeroLerp(client))
    {
        g_bInitialZeroLerp[client] = false;
    }

    bool initialZeroLerp = g_bInitialZeroLerp[client] && IsInitialZeroLerp(client);

    float newLerpTime = GetLerpTime(client);

    // The server may calculate 9.5 ms from 1/105 Hz for the initial 0/0
    // values. Treat that initial state as the configured 10 ms minimum.
    if (initialZeroLerp)
    {
        newLerpTime = cVarMinLerp.FloatValue;
    }

    // Keep the entity's lerp in sync with the accepted/calculated value.
    SetEntPropFloat(client, Prop_Data, "m_fLerpTime", newLerpTime);

    if (GetClientTeam(client) < L4D_TEAM_SURVIVORS)
    {
        return;
    }

    char steamID[STEAMID_SIZE];
    GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

    if (!initialZeroLerp &&
        (FloatCompare(newLerpTime, cVarMinLerp.FloatValue) == -1 ||
         FloatCompare(newLerpTime, cVarMaxLerp.FloatValue) == 1))
    {
        // Notify player and suggest client console commands.
        PrintLerpFixSuggestion(client, newLerpTime);

        if (!load)
        {
            float currentLerpTime = 0.0;

            if (ArrLerpsValue.GetValue(steamID, currentLerpTime))
            {
                if (currentLerpTime == newLerpTime)
                {
                    if (cVarBadLerpAction.IntValue == 1)
                    {
                        ChangeClientTeam(client, L4D_TEAM_SPECTATE);
                    }
                    else
                    {
                        KickClient(client,
                            "Illegal lerp value (min: %.01f, max: %.01f)",
                            cVarMinLerp.FloatValue * 1000.0,
                            cVarMaxLerp.FloatValue * 1000.0);
                    }

                    return;
                }
            }

            if (cVarBadLerpAction.IntValue == 1)
            {
                CPrintToChatAllEx(client,
                    "{default}<{olive}Lerp{default}> {teamcolor}%N {default}was moved to spectators for lerp {teamcolor}%.01f",
                    client, newLerpTime * 1000.0);

                CPrintToChatEx(client, client,
                    "{default}<{olive}Lerp{default}> Illegal lerp value (min: {teamcolor}%.01f{default}, max: {teamcolor}%.01f{default})",
                    cVarMinLerp.FloatValue * 1000.0,
                    cVarMaxLerp.FloatValue * 1000.0);

                ChangeClientTeam(client, L4D_TEAM_SPECTATE);
            }
            else
            {
                CPrintToChatAllEx(client,
                    "{default}<{olive}Lerp{default}> {teamcolor}%N {default}was kicked for lerp {teamcolor}%.01f",
                    client, newLerpTime * 1000.0);

                KickClient(client,
                    "Illegal lerp value (min: %.01f, max: %.01f)",
                    cVarMinLerp.FloatValue * 1000.0,
                    cVarMaxLerp.FloatValue * 1000.0);
            }
        }

        return;
    }

    float currentLerpTime = 0.0;

    if (!ArrLerpsValue.GetValue(steamID, currentLerpTime))
    {
        if (team && cVarShowLerpTeamChange.BoolValue)
        {
            CPrintToChatAllEx(client,
                "{default}<{olive}Lerp{default}> {teamcolor}%N {default}@ {teamcolor}%.01f",
                client, newLerpTime * 1000.0);
        }

        ArrLerpsValue.SetValue(steamID, newLerpTime, true);
        //ArrLerpsCountChanges.SetValue(steamID, 0, true);
        return;
    }

    if (currentLerpTime == newLerpTime)
    {
        if (team && cVarShowLerpTeamChange.BoolValue)
        {
            CPrintToChatAllEx(client,
                "{default}<{olive}Lerp{default}> {teamcolor}%N {default}@ {teamcolor}%.01f",
                client, newLerpTime * 1000.0);
        }

        return;
    }

    if (isMatchLife || !cVarReadyUpLerpChanges.BoolValue)
    {
        int count = 0;
        ArrLerpsCountChanges.GetValue(steamID, count);
        count++;

        int max = cVarAllowedLerpChanges.IntValue;

        CPrintToChatAllEx(client,
            "{default}<{olive}Lerp{default}> {teamcolor}%N {default}@ {teamcolor}%.01f {default}<== {green}%.01f {default}[%s%d{default}/%d {olive}changes]",
            client, newLerpTime * 1000.0, currentLerpTime * 1000.0,
            ((count > max) ? "{teamcolor} " : ""), count, max);

        if (cVarLerpChangeSpec.BoolValue && count > max)
        {
            CPrintToChatAllEx(client,
                "{default}<{olive}Lerp{default}> {teamcolor}%N {default}was moved to spectators (illegal lerp change)!",
                client);

            ChangeClientTeam(client, L4D_TEAM_SPECTATE);

            CPrintToChatEx(client, client,
                "{default}<{olive}Lerp{default}> Illegal change of Lerp midgame! Change it back to {teamcolor}%.01f",
                currentLerpTime * 1000.0);

            return;
        }

        ArrLerpsCountChanges.SetValue(steamID, count);
    }
    else
    {
        CPrintToChatAllEx(client,
            "{default}<{olive}Lerp{default}> {teamcolor}%N {default}@ {teamcolor}%.01f {default}<== {green}%.01f",
            client, newLerpTime * 1000.0, currentLerpTime * 1000.0);
    }

    ArrLerpsValue.SetValue(steamID, newLerpTime);
}

/**
 * Sends a correction message when the calculated lerp is outside the
 * configured interval. Notifications are rate-limited to avoid chat spam.
 */
void PrintLerpFixSuggestion(int client, float currentLerp)
{
    if (client < 1 || client > MaxClients ||
        !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    float now = GetGameTime();

    if (now - g_fLastLerpWarning[client] < 5.0)
    {
        return;
    }

    g_fLastLerpWarning[client] = now;

    float minLerp = cVarMinLerp.FloatValue;
    float maxLerp = cVarMaxLerp.FloatValue;

    char buffer[64];
    int updateRate = 100;

    if (GetClientInfo(client, "cl_updaterate", buffer, sizeof(buffer)))
    {
        updateRate = StringToInt(buffer);
    }

    if (cVarMinUpdateRate != null && cVarMaxUpdateRate != null)
    {
        updateRate = RoundFloat(clamp(
            float(updateRate),
            cVarMinUpdateRate.FloatValue,
            cVarMaxUpdateRate.FloatValue));
    }

    if (updateRate <= 0)
    {
        updateRate = 100;
    }

    float ratioMin = 0.0;
    float ratioMax = 100.0;

    if (cVarMinInterpRatio != null)
    {
        ratioMin = cVarMinInterpRatio.FloatValue;
    }

    if (cVarMaxInterpRatio != null)
    {
        ratioMax = cVarMaxInterpRatio.FloatValue;
    }

    // -1 means no server restriction for that ratio bound.
    if (ratioMin < 0.0)
    {
        ratioMin = 0.0;
    }

    if (ratioMax < 0.0)
    {
        ratioMax = 100.0;
    }

    float suggestedInterp;
    float suggestedRatio;

    CPrintToChatEx(client, client,
        "{default}<{olive}Lerp{default}> Seu lerp atual: {teamcolor}%.1f ms{default}. Limites do servidor: {teamcolor}%.1f - %.1f ms{default}.",
        currentLerp * 1000.0,
        minLerp * 1000.0,
        maxLerp * 1000.0);

    if (currentLerp < minLerp)
	{
		// The minimum allowed lerp is 0.01 seconds (10 ms).
		suggestedInterp = 0.01;

		suggestedRatio = ratioMin;

		CPrintToChatEx(client, client,
			"{default}<{olive}Lerp{default}> Seu lerp está {teamcolor}abaixo do mínimo{default}. Execute no console:");

		CPrintToChatEx(client, client,
			"{default} {olive}cl_interp 0.01");

		CPrintToChatEx(client, client,
			"{default} {olive}cl_interp_ratio %.0f",
			suggestedRatio);
	}
    else if (currentLerp > maxLerp)
    {
        suggestedInterp = maxLerp;

        int ratio = RoundToFloor(maxLerp * float(updateRate));
        suggestedRatio = clamp(float(ratio), ratioMin, ratioMax);

        CPrintToChatEx(client, client,
            "{default}<{olive}Lerp{default}> Seu lerp está {teamcolor}acima do máximo{default}. Execute no console:");

        CPrintToChatEx(client, client,
            "{default} {olive}cl_interp %.3f",
            suggestedInterp);

        CPrintToChatEx(client, client,
            "{default} {olive}cl_interp_ratio %.0f",
            suggestedRatio);
    }

    CPrintToChatEx(client, client,
        "{default}<{olive}Lerp{default}> Abra o console com {olive}`{default} e cole os comandos acima.");
}

bool IsInitialZeroLerp(int client)
{
    char buffer[64];

    if (!GetClientInfo(client, "cl_interp", buffer, sizeof(buffer)))
    {
        return false;
    }

    float interp = StringToFloat(buffer);

    if (!GetClientInfo(client, "cl_interp_ratio", buffer, sizeof(buffer)))
    {
        return false;
    }

    float ratio = StringToFloat(buffer);

    return interp == 0.0 && ratio == 0.0;
}

float GetLerpTime(int client)
{
    char buffer[64];

    if (!GetClientInfo(client, "cl_updaterate", buffer, sizeof(buffer)))
    {
        buffer = "";
    }

    int updateRate = StringToInt(buffer);

    updateRate = RoundFloat(clamp(
        float(updateRate),
        cVarMinUpdateRate.FloatValue,
        cVarMaxUpdateRate.FloatValue));

    if (!GetClientInfo(client, "cl_interp_ratio", buffer, sizeof(buffer)))
    {
        buffer = "";
    }

    float flLerpRatio = StringToFloat(buffer);

    if (!GetClientInfo(client, "cl_interp", buffer, sizeof(buffer)))
    {
        buffer = "";
    }

    float flLerpAmount = StringToFloat(buffer);

    if (cVarMinInterpRatio != null && cVarMaxInterpRatio != null &&
        cVarMinInterpRatio.FloatValue != -1.0)
    {
        flLerpRatio = clamp(
            flLerpRatio,
            cVarMinInterpRatio.FloatValue,
            cVarMaxInterpRatio.FloatValue);
    }

    return maximum(flLerpAmount, flLerpRatio / float(updateRate));
}

float maximum(float a, float b)
{
    return (a > b) ? a : b;
}

float clamp(float inc, float low, float high)
{
    return (inc > high) ? high : ((inc < low) ? low : inc);
}

int LM_GetLerpTime(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);

    char sSteamID[STEAMID_SIZE];
    GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID));

    float fLerpValue = -1.0;

    if (ArrLerpsValue.GetValue(sSteamID, fLerpValue))
    {
        return view_as<int>(fLerpValue);
    }

    return view_as<int>(GetLerpTime(client));
}

int LM_GetCurrentLerpTime(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return view_as<int>(GetLerpTime(client));
}

int LM_GetStoredLerpTime(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);

    char sSteamID[STEAMID_SIZE];
    GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID));

    float fLerpValue = -1.0;

    if (ArrLerpsValue.GetValue(sSteamID, fLerpValue))
    {
        return view_as<int>(fLerpValue);
    }

    return view_as<int>(-1.0);
}

Action Lerps_Cmd(int client, int args)
{
    int iCount = 0;

    if (ArrLerpsValue.Size > 0)
    {
        ReplyToCommand(client, "[!] Lerp setting list:");

        float fLerpValue;
        char sSteamID[STEAMID_SIZE];

        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                GetClientAuthId(i, AuthId_Steam2, sSteamID, sizeof(sSteamID));

                if (ArrLerpsValue.GetValue(sSteamID, fLerpValue))
                {
                    ReplyToCommand(client, "%N [%s]: %.01f", i, sSteamID, fLerpValue * 1000.0);
                    iCount++;
                }
            }
        }
    }

    if (iCount == 0)
    {
        ReplyToCommand(client, "There is nothing here!");
    }

    return Plugin_Handled;
}