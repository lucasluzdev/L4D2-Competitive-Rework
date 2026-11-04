/*========================================================
    L4D2 Tank Damage Announce (Fixed Tank HP Support)
========================================================*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <colors>

#define TEAM_SURVIVOR         2
#define TEAM_INFECTED         3
#define ZOMBIECLASS_TANK      8

#define FIXED_TANK_HP         8000.0

bool g_bEnabled = true;
bool g_bAnnounceTankDamage = false;
bool g_bIsTankInPlay = false;
bool g_bPrintedHealth = false;

int g_iWasTank[MAXPLAYERS + 1];
int g_iWasTankAI = 0;

int g_iOffset_Incapacitated = 0;
int g_iTankClient = 0;
int g_iLastTankHealth = 0;
int g_iSurvivorLimit = 4;

int g_iDamage[MAXPLAYERS + 1];

float g_fMaxTankHealth = FIXED_TANK_HP;

ConVar g_hCvarEnabled;
ConVar g_hCvarSurvivorLimit;

Handle g_hForwardTankDeath = INVALID_HANDLE;

public Plugin myinfo =
{
    name = "Tank Damage Announce L4D2",
    author = "Griffin, Blade, Vann09",
    description = "Announce damage dealt to tanks",
    version = "1.1"
};

public void OnPluginStart()
{
    HookEvent("tank_spawn", Event_TankSpawn);
    HookEvent("player_death", Event_PlayerKilled);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("player_hurt", Event_PlayerHurt);

    g_hCvarEnabled = CreateConVar(
        "l4d_tankdamage_enabled",
        "1",
        "Enable tank damage announce",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    g_hCvarSurvivorLimit = FindConVar("survivor_limit");

    HookConVarChange(g_hCvarEnabled, Cvar_Enabled);
    HookConVarChange(g_hCvarSurvivorLimit, Cvar_SurvivorLimit);

    g_bEnabled = g_hCvarEnabled.BoolValue;

    g_iOffset_Incapacitated =
        FindSendPropInfo("Tank", "m_isIncapacitated");

    g_hForwardTankDeath =
        CreateGlobalForward("OnTankDeath", ET_Event);

    ClearTankDamage();
}

public void OnMapStart()
{
    ClearTankDamage();

    PrecacheSound("ui/pickup_secret01.wav");
}

public void OnClientDisconnect_Post(int client)
{
    if (!g_bIsTankInPlay || client != g_iTankClient)
        return;

    CreateTimer(0.1, Timer_CheckTank, client);
}

public void Cvar_Enabled(
    ConVar convar,
    const char[] oldValue,
    const char[] newValue
)
{
    g_bEnabled = StringToInt(newValue) > 0;
}

public void Cvar_SurvivorLimit(
    ConVar convar,
    const char[] oldValue,
    const char[] newValue
)
{
    g_iSurvivorLimit = StringToInt(newValue);
}

public void Event_PlayerHurt(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    if (!g_bIsTankInPlay)
        return;

    int victim =
        GetClientOfUserId(event.GetInt("userid"));

    if (
        victim != GetTankClient()
        || IsTankDying()
    )
    {
        return;
    }

    int attacker =
        GetClientOfUserId(event.GetInt("attacker"));

    if (
        attacker <= 0
        || !IsClientInGame(attacker)
        || GetClientTeam(attacker) != TEAM_SURVIVOR
    )
    {
        return;
    }

    g_iDamage[attacker] +=
        event.GetInt("dmg_health");

    g_iLastTankHealth =
        event.GetInt("health");
}

public void Event_PlayerKilled(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    if (!g_bIsTankInPlay)
        return;

    int victim =
        GetClientOfUserId(event.GetInt("userid"));

    if (victim != g_iTankClient)
        return;

    int attacker =
        GetClientOfUserId(event.GetInt("attacker"));

    if (
        attacker > 0
        && IsClientInGame(attacker)
    )
    {
        g_iDamage[attacker] += g_iLastTankHealth;
    }

    if (!IsFakeClient(victim))
        g_iWasTank[victim] = 1;
    else
        g_iWasTankAI = 1;

    CreateTimer(0.1, Timer_CheckTank, victim);
}

public void Event_TankSpawn(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    int client =
        GetClientOfUserId(event.GetInt("userid"));

    g_iTankClient = client;

    if (g_bIsTankInPlay)
        return;

    EmitSoundToAll(
        "ui/pickup_secret01.wav",
        _,
        SNDCHAN_AUTO,
        SNDLEVEL_NORMAL,
        SND_NOFLAGS,
        0.8
    );

    g_bAnnounceTankDamage = true;
    g_bIsTankInPlay = true;

    // Force Tank HP
    SetEntProp(client, Prop_Data, "m_iHealth", 8000);
    SetEntProp(client, Prop_Data, "m_iMaxHealth", 8000);

    g_iLastTankHealth = 8000;

    // Force correct percentage calculation
    g_fMaxTankHealth = FIXED_TANK_HP;

    PrintToServer("[TankDamage] Tank HP forced to 8000");
}

public void Event_RoundStart(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    g_bPrintedHealth = false;
    g_bIsTankInPlay = false;
    g_iTankClient = 0;

    ClearTankDamage();
}

public void Event_RoundEnd(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    if (g_bAnnounceTankDamage)
    {
        PrintRemainingHealth();
        PrintTankDamage();
    }

    ClearTankDamage();
}

public Action Timer_CheckTank(
    Handle timer,
    any oldtankclient
)
{
    if (g_iTankClient != oldtankclient)
        return Plugin_Stop;

    int tankclient = FindTankClient();

    if (
        tankclient
        && tankclient != oldtankclient
    )
    {
        g_iTankClient = tankclient;
        return Plugin_Stop;
    }

    if (g_bAnnounceTankDamage)
        PrintTankDamage();

    ClearTankDamage();

    g_bIsTankInPlay = false;

    Call_StartForward(g_hForwardTankDeath);
    Call_Finish();

    return Plugin_Stop;
}

bool IsTankDying()
{
    int tankclient = GetTankClient();

    if (!tankclient)
        return false;

    return view_as<bool>(
        GetEntData(
            tankclient,
            g_iOffset_Incapacitated
        )
    );
}

void PrintRemainingHealth()
{
    g_bPrintedHealth = true;

    if (!g_bEnabled)
        return;

    int tankclient = GetTankClient();

    if (!tankclient)
        return;

    char name[MAX_NAME_LENGTH];

    if (IsFakeClient(tankclient))
        strcopy(name, sizeof(name), "AI");
    else
        GetClientName(
            tankclient,
            name,
            sizeof(name)
        );

    CPrintToChatAll(
        "{default}[{green}!{default}] {blue}Tank {default}({olive}%s{default}) had {green}%d {default}health remaining",
        name,
        g_iLastTankHealth
    );
}

void PrintTankDamage()
{
    if (!g_bEnabled)
        return;

    if (!g_bPrintedHealth)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_iWasTank[i] > 0)
            {
                char name[MAX_NAME_LENGTH];

                GetClientName(
                    i,
                    name,
                    sizeof(name)
                );

                CPrintToChatAll(
                    "{default}[{green}!{default}] {blue}Damage dealt to Tank {default}({olive}%s{default})",
                    name
                );

                g_iWasTank[i] = 0;
            }
            else if (g_iWasTankAI > 0)
            {
                CPrintToChatAll(
                    "{default}[{green}!{default}] {blue}Damage dealt to Tank {default}({olive}AI{default})"
                );

                g_iWasTankAI = 0;
            }
        }
    }

    int client;
    int survivor_index = -1;

    int survivor_clients[MAXPLAYERS + 1];

    for (client = 1; client <= MaxClients; client++)
    {
        if (
            !IsClientInGame(client)
            || GetClientTeam(client) != TEAM_SURVIVOR
            || g_iDamage[client] <= 0
        )
        {
            continue;
        }

        survivor_index++;
        survivor_clients[survivor_index] = client;
    }

    SortCustom1D(
        survivor_clients,
        survivor_index + 1,
        SortByDamageDesc
    );

    for (int k = 0; k <= survivor_index; k++)
    {
        client = survivor_clients[k];

        int damage = g_iDamage[client];

        int percent_damage =
            GetDamageAsPercent(damage);

        CPrintToChatAll(
            "{blue}[{default}%d{blue}] ({default}%d%%{blue}) {olive}%N",
            damage,
            percent_damage,
            client
        );
    }
}

void ClearTankDamage()
{
    g_iLastTankHealth = 0;
    g_iWasTankAI = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_iDamage[i] = 0;
        g_iWasTank[i] = 0;
    }

    g_bAnnounceTankDamage = false;
}

int GetTankClient()
{
    if (!g_bIsTankInPlay)
        return 0;

    int tankclient = g_iTankClient;

    if (!IsClientInGame(tankclient))
    {
        tankclient = FindTankClient();

        if (!tankclient)
            return 0;

        g_iTankClient = tankclient;
    }

    return tankclient;
}

int FindTankClient()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (
            !IsClientInGame(client)
            || GetClientTeam(client) != TEAM_INFECTED
            || !IsPlayerAlive(client)
            || GetEntProp(
                client,
                Prop_Send,
                "m_zombieClass"
            ) != ZOMBIECLASS_TANK
        )
        {
            continue;
        }

        return client;
    }

    return 0;
}

int GetDamageAsPercent(int damage)
{
    return RoundToNearest(
        (float(damage) / g_fMaxTankHealth) * 100.0
    );
}

public int SortByDamageDesc(
    int elem1,
    int elem2,
    const int[] array,
    Handle hndl
)
{
    if (g_iDamage[elem1] > g_iDamage[elem2])
        return -1;

    if (g_iDamage[elem2] > g_iDamage[elem1])
        return 1;

    if (elem1 > elem2)
        return -1;

    if (elem2 > elem1)
        return 1;

    return 0;
}
