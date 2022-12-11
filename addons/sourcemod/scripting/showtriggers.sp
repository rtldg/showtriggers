#include <sourcemod>

#include <sdkhooks>
#include <sdktools>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "2.1.0"

// Entity is completely ignored by the client.
// Can cause prediction errors if a player proceeds to collide with it on the server.
// https://developer.valvesoftware.com/wiki/Effects_enum
#define EF_NODRAW 32

int gI_EffectsOffset = -1;
bool gB_ShowTriggers[MAXPLAYERS+1];

// Used to determine whether to avoid unnecessary SetTransmit hooks.
int gI_TransmitCount;

StringMap gSM_HammerIdToColor = null;

public Plugin myinfo =
{
	name = "Show Triggers",
	author = "ici, Eric, rtldg",
	description = "Make trigger brushes visible.",
	version = PLUGIN_VERSION,
	url = "https://github.com/rtldg/showtriggers"
};

public void OnPluginStart()
{
	gSM_HammerIdToColor = new StringMap();

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

public void OnMapStart()
{
	gSM_HammerIdToColor.Clear();

	for (int i, n = EntityLump.Length(); i < n; i++)
	{
		EntityLumpEntry entry = EntityLump.Get(i);
		char buffer[100], hammerid[12];
		if (-1 == entry.GetNextKey("classname", buffer, sizeof(buffer))) continue;
		if (!StrEqual(buffer, "trigger_multiple")) continue;
		if (-1 == entry.GetNextKey("hammerid", hammerid, sizeof(hammerid))) continue;

		int color = 0;

		for (int start = -1; -1 != (start = entry.GetNextKey("OnStartTouch", buffer, sizeof(buffer), start)); )
		{
			int pos = StrContains(buffer, "gravity ");

			if (pos != -1 && '1' <= buffer[pos+8] <= '9')
			{
				color = 0x7FFF00FF; // 127 255 0 255
				break;
			}
		}

		for (int start = -1; -1 != (start = entry.GetNextKey("OnEndTouch", buffer, sizeof(buffer), start)); )
		{
			if (-1 != StrContains(buffer, "gravity -")
			||  -1 != StrContains(buffer, "basevelocity"))
			{
				color = 0xFF7F00FF; // 255 127 0 255
				break;
			}
		}

		if (color) gSM_HammerIdToColor.SetValue(hammerid, color);
	}
}

public void OnRoundStartPost(Event event, const char[] name, bool dontBroadcast)
{
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, "trigger_*")) != -1)
	{
		SetTriggerRenderColor(entity);
	}
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

void SetTriggerRenderColor(int entity)
{
	char classname[32];
	GetEntityClassname(entity, classname, sizeof(classname));

	SetEntityRenderMode(entity, RENDER_TRANSCOLOR);

	if (strcmp(classname, "trigger_multiple") == 0)
	{
		int color;
		char hammerid[12];
		IntToString(GetEntProp(entity, Prop_Data, "m_iHammerID"), hammerid, sizeof(hammerid));

		if (!gSM_HammerIdToColor.GetValue(hammerid, color))
			color = 0x00FF00FF; // 0 255 0 255

		SetEntityRenderColor(
			entity,
			(color >> 24) & 0xFF,
			(color >> 16) & 0xFF,
			(color >>  8) & 0xFF,
			(color      ) & 0xFF
		);
	}
	else if (strcmp(classname, "trigger_push")  == 0)
	{
		SetEntityRenderColor(entity, 255, 127, 0, 255);
	}
	else if (strcmp(classname, "trigger_teleport") == 0)
	{
		SetEntityRenderColor(entity, 255, 0, 0, 255);
	}
	else
	{
		SetEntityRenderColor(entity, 0, 0, 0, 255);
	}
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
