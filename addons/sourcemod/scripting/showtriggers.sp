#include <sourcemod>

#include <sdkhooks>
#include <sdktools>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "1.1"

// Entity is completely ignored by the client.
// Can cause prediction errors if a player proceeds to collide with it on the server.
// https://developer.valvesoftware.com/wiki/Effects_enum
#define EF_NODRAW 32

int gI_EffectsOffset = -1;
bool gB_ShowTriggers[MAXPLAYERS+1];

// Used to determine whether to avoid unnecessary SetTransmit hooks.
int gI_TransmitCount;

public Plugin myinfo =
{
	name = "Show Triggers",
	author = "ici",
	description = "Make trigger brushes visible.",
	version = PLUGIN_VERSION,
	url = "http://steamcommunity.com/id/1ci"
};

public void OnPluginStart()
{
	gI_EffectsOffset = FindSendPropInfo("CBaseEntity", "m_fEffects");

	if (gI_EffectsOffset == -1)
	{
		SetFailState("[Show Triggers] Could not find \"m_fEffects\" offset.");
	}

	CreateConVar("showtriggers_version", PLUGIN_VERSION, "Show triggers plugin version.", FCVAR_NOTIFY | FCVAR_REPLICATED);

	HookEvent("round_start", OnRoundStartPost, EventHookMode_Post);

	RegConsoleCmd("sm_showtriggers", Command_ShowTriggers, "Command to dynamically toggle trigger visibility.");
	RegConsoleCmd("sm_st", Command_ShowTriggers, "Command to dynamically toggle trigger visibility.");
}

public void OnClientPutInServer(int client)
{
	gB_ShowTriggers[client] = false;
}

public void OnClientDisconnect_Post(int client)
{
	// Has this player been still using the feature before he left?
	if (!gB_ShowTriggers[client])
	{
		return;
	}

	gB_ShowTriggers[client] = false;
	gI_TransmitCount--;
	TransmitTriggers(gI_TransmitCount > 0);
}

public Action Command_ShowTriggers(int client, int args)
{
	if (!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	gB_ShowTriggers[client] = !gB_ShowTriggers[client];

	if (gB_ShowTriggers[client])
	{
		gI_TransmitCount++;
		PrintToChat(client, "[Show Triggers] Showing trigger brushes.");
	}
	else
	{
		gI_TransmitCount--;
		PrintToChat(client, "[Show Triggers] Stopped showing trigger brushes.");
	}

	TransmitTriggers(gI_TransmitCount > 0);
	return Plugin_Handled;
}

// https://forums.alliedmods.net/showthread.php?p=2423363
// https://sm.alliedmods.net/api/index.php?fastload=file&id=4&
// https://developer.valvesoftware.com/wiki/Networking_Entities
// https://github.com/ValveSoftware/source-sdk-2013/blob/master/sp/src/game/server/triggers.cpp#L58
void TransmitTriggers(bool transmit)
{
	// Hook only once.
	static bool hooked = false;

	// Have we done this before?
	if (hooked == transmit)
	{
		return;
	}

	char classname[8];

	// Loop through entities.
	for (int entity = MaxClients + 1; entity <= GetEntityCount(); ++entity)
	{
		if (!IsValidEdict(entity))
		{
			continue;
		}

		// Is this entity a trigger?
		GetEdictClassname(entity, classname, sizeof(classname));
		if (strcmp(classname, "trigger") != 0)
		{
			continue;
		}

		// Is this entity's model a VBSP model?
		GetEntPropString(entity, Prop_Data, "m_ModelName", classname, 2);
		if (classname[0] != '*')
		{
			// The entity must have been created by a plugin and assigned some random model.
			// Skipping in order to avoid console spam.
			continue;
		}

		// Get flags.
		int effectFlags = GetEntData(entity, gI_EffectsOffset);
		int edictFlags = GetEdictFlags(entity);

		// Determine whether to transmit or not.
		if (transmit)
		{
			effectFlags &= ~EF_NODRAW;
			edictFlags &= ~FL_EDICT_DONTSEND;
		}
		else
		{
			effectFlags |= EF_NODRAW;
			edictFlags |= FL_EDICT_DONTSEND;
		}

		// Apply state changes.
		SetEntData(entity, gI_EffectsOffset, effectFlags);
		ChangeEdictState(entity, gI_EffectsOffset);
		SetEdictFlags(entity, edictFlags);

		// Should we hook?
		if (transmit)
		{
			SDKHook(entity, SDKHook_SetTransmit, OnSetTransmit);
		}
		else
		{
			SDKUnhook(entity, SDKHook_SetTransmit, OnSetTransmit);
		}
	}

	hooked = transmit;
}

public Action OnSetTransmit(int entity, int client)
{
	if (!gB_ShowTriggers[client])
	{
		// I will not display myself to this client :(
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

stock bool IsValidClient(int client)
{
	return (0 < client && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}
