#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.1"

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

public Plugin myinfo =
{
    name = "Festa de Aniversario",
    author = "Vann09",
    description = "Evento de aniversario leve",
    version = PLUGIN_VERSION,
    url = "https://www.sourcemod.net"
};

#define MAX_ENTITIES 2048

int g_iHatRef[MAX_ENTITIES + 1];

Handle g_hBirthdayTimer = null;
Handle g_hCommonTimer = null;

ConVar g_hEnable;
ConVar g_hName;
ConVar g_hInterval;
ConVar g_hSounds;
ConVar g_hCommons;

char g_sPartySounds[][] =
{
    "buttons/button14.wav",
    "buttons/blip1.wav",
    "ui/alert_clink.wav"
};

public void OnPluginStart()
{
    g_hEnable = CreateConVar(
        "sm_birthday_enable",
        "1"
    );

    g_hName = CreateConVar(
        "sm_birthday_name",
        "ATHENAAASS"
    );

    g_hInterval = CreateConVar(
        "sm_birthday_interval",
        "240"
    );

    g_hSounds = CreateConVar(
        "sm_birthday_sounds",
        "1"
    );

    g_hCommons = CreateConVar(
        "sm_birthday_commons",
        "1",
        "Adiciona chapeu em infectados comuns"
    );

    HookEvent(
        "player_spawn",
        Event_PlayerSpawn
    );

    HookEvent(
        "player_death",
        Event_PlayerDeath
    );

    AutoExecConfig(
        true,
        "l4d2_festa_aniversario"
    );
}

public void OnMapStart()
{
    PrecacheModel(
        "models/props_junk/gnome.mdl",
        true
    );

    for (int i = 0; i < sizeof(g_sPartySounds); i++)
    {
        PrecacheSound(
            g_sPartySounds[i],
            true
        );
    }

    StartBirthdayTimer();
    StartCommonTimer();
}

public void OnMapEnd()
{
    KillBirthdayTimer();
    KillCommonTimer();
}

void StartBirthdayTimer()
{
    KillBirthdayTimer();

    g_hBirthdayTimer = CreateTimer(
        g_hInterval.FloatValue,
        Timer_BirthdayMessage,
        _,
        TIMER_REPEAT
    );
}

void KillBirthdayTimer()
{
    if (g_hBirthdayTimer != null)
    {
        KillTimer(g_hBirthdayTimer);
        g_hBirthdayTimer = null;
    }
}

void StartCommonTimer()
{
    KillCommonTimer();

    g_hCommonTimer = CreateTimer(
        5.0,
        Timer_ProcessCommons,
        _,
        TIMER_REPEAT
    );
}

void KillCommonTimer()
{
    if (g_hCommonTimer != null)
    {
        KillTimer(g_hCommonTimer);
        g_hCommonTimer = null;
    }
}

public Action Timer_BirthdayMessage(
    Handle timer
)
{
    if (!g_hEnable.BoolValue)
        return Plugin_Continue;

    char sName[128];

    g_hName.GetString(
        sName,
        sizeof(sName)
    );

    PrintToChatAll(
        "\x04[Festa]\x01 Feliz aniversario \x04%s!!",
        sName
    );

    PrintToChatAll(
        "\x03Muita paz, felicidade e \x04L4D2\x03 pra vc!!!"
    );

    if (g_hSounds.BoolValue)
    {
        int rnd = GetRandomInt(
            0,
            sizeof(g_sPartySounds) - 1
        );

        EmitSoundToAll(
            g_sPartySounds[rnd],
            SOUND_FROM_PLAYER,
            SNDCHAN_AUTO,
            SNDLEVEL_NORMAL
        );
    }

    return Plugin_Continue;
}

public Action Event_PlayerSpawn(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    if (!g_hEnable.BoolValue)
        return Plugin_Continue;

    int client = GetClientOfUserId(
        event.GetInt("userid")
    );

    if (!IsValidClient(client))
        return Plugin_Continue;

    if (GetClientTeam(client) != 2)
        return Plugin_Continue;

    CreateTimer(
        0.5,
        Timer_AttachHat,
        GetClientUserId(client),
        TIMER_FLAG_NO_MAPCHANGE
    );

    return Plugin_Continue;
}

public Action Timer_AttachHat(
    Handle timer,
    any userid
)
{
    int client = GetClientOfUserId(userid);

    if (!IsValidClient(client))
        return Plugin_Stop;

    if (!IsPlayerAlive(client))
        return Plugin_Stop;

    CreateSurvivorHat(client);

    return Plugin_Stop;
}

public Action Timer_ProcessCommons(
    Handle timer
)
{
    if (!g_hEnable.BoolValue)
        return Plugin_Continue;

    if (!g_hCommons.BoolValue)
        return Plugin_Continue;

    int entity = -1;

    while (
        (entity = FindEntityByClassname(
            entity,
            "infected"
        )) != -1
    )
    {
        if (
            HasEntProp(
                entity,
                Prop_Data,
                "m_iHammerID"
            )
        )
        {
            int hammer =
                GetEntProp(
                    entity,
                    Prop_Data,
                    "m_iHammerID"
                );

            if (hammer == 1337)
                continue;
        }

        CreateCommonHat(entity);

        if (
            HasEntProp(
                entity,
                Prop_Data,
                "m_iHammerID"
            )
        )
        {
            SetEntProp(
                entity,
                Prop_Data,
                "m_iHammerID",
                1337
            );
        }
    }

    return Plugin_Continue;
}

void CreateCommonHat(int entity)
{
    int hat = CreateEntityByName(
        "prop_dynamic_override"
    );

    if (hat == -1)
        return;

    DispatchKeyValue(
        hat,
        "model",
        "models/props_junk/gnome.mdl"
    );

    DispatchSpawn(hat);

    SetEntProp(
        hat,
        Prop_Send,
        "m_nSolidType",
        0
    );

    AcceptEntityInput(
        hat,
        "DisableShadow"
    );

    SetVariantString("!activator");

    AcceptEntityInput(
        hat,
        "SetParent",
        entity
    );

    SetVariantString("mouth");

    AcceptEntityInput(
        hat,
        "SetParentAttachmentMaintainOffset"
    );

    float pos[3];

    pos[0] = 0.0;
    pos[1] = 0.0;
    pos[2] = 8.0;

    float ang[3];

    ang[0] = 0.0;
    ang[1] = 0.0;
    ang[2] = 0.0;

    TeleportEntity(
        hat,
        pos,
        ang,
        NULL_VECTOR
    );

    SetEntPropFloat(
        hat,
        Prop_Send,
        "m_flModelScale",
        0.30
    );
}

void CreateSurvivorHat(int client)
{
    RemoveBirthdayHat(client);

    int hat = CreateEntityByName(
        "prop_dynamic_override"
    );

    if (hat == -1)
        return;

    DispatchKeyValue(
        hat,
        "model",
        "models/props_junk/gnome.mdl"
    );

    DispatchSpawn(hat);

    SetEntProp(
        hat,
        Prop_Send,
        "m_nSolidType",
        0
    );

    AcceptEntityInput(
        hat,
        "DisableShadow"
    );

    SetVariantString("!activator");

    AcceptEntityInput(
        hat,
        "SetParent",
        client
    );

    SetVariantString("eyes");

    AcceptEntityInput(
        hat,
        "SetParentAttachmentMaintainOffset"
    );

    float pos[3];

    pos[0] = 0.0;
    pos[1] = 0.0;
    pos[2] = 5.0;

    float ang[3];

    ang[0] = 0.0;
    ang[1] = 0.0;
    ang[2] = 0.0;

    TeleportEntity(
        hat,
        pos,
        ang,
        NULL_VECTOR
    );

    SetEntPropFloat(
        hat,
        Prop_Send,
        "m_flModelScale",
        0.28
    );

    SDKHook(
        hat,
        SDKHook_SetTransmit,
        Hook_HatTransmit
    );

    g_iHatRef[client] =
        EntIndexToEntRef(hat);
}

public Action Hook_HatTransmit(
    int entity,
    int client
)
{
    if (!IsValidClient(client))
        return Plugin_Continue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (
            g_iHatRef[i] != 0 &&
            EntRefToEntIndex(
                g_iHatRef[i]
            ) == entity
        )
        {
            if (client == i)
            {
                return Plugin_Handled;
            }

            break;
        }
    }

    return Plugin_Continue;
}

void RemoveBirthdayHat(int client)
{
    if (client <= 0)
        return;

    if (g_iHatRef[client] == 0)
        return;

    int hat = EntRefToEntIndex(
        g_iHatRef[client]
    );

    if (
        hat != INVALID_ENT_REFERENCE &&
        IsValidEntity(hat)
    )
    {
        RemoveEntity(hat);
    }

    g_iHatRef[client] = 0;
}

public Action Event_PlayerDeath(
    Event event,
    const char[] name,
    bool dontBroadcast
)
{
    int client = GetClientOfUserId(
        event.GetInt("userid")
    );

    if (client > 0)
    {
        RemoveBirthdayHat(client);
    }

    return Plugin_Continue;
}

bool IsValidClient(int client)
{
    if (client <= 0)
        return false;

    if (client > MaxClients)
        return false;

    if (!IsClientInGame(client))
        return false;

    return true;
}