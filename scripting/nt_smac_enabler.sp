#include <sourcemod>
#include <sdkhooks>
#include <dhooks>

#include <neotokyo>

#define DMGTYPE_SMAC -4194304

Handle _dh = INVALID_HANDLE;

bool _late;

ConVar _smac_dmg;
ConVar _smac_vip_only;

public Plugin myinfo = {
	name = "SMAC enabler",
	description = "Enables players to pick up SMAC and optionally restricts it to VIP only",
	author = "Rain, edits by bauxite",
	version = "0.3.3",
	url = "",
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	_late = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	_smac_dmg = CreateConVar("sm_smac_dmg", "17", "How much damage should the SMAC do, per hit.");
	_smac_vip_only = CreateConVar("sm_smac_vip_only", "1", "Should SMAC be pickable by VIP only", _, true, 0.0, true, 1.0);
	
	_dh = new DynamicHook(326, HookType_Entity, ReturnType_Bool,
		ThisPointer_CBaseEntity);
	if (_dh == INVALID_HANDLE)
	{
		SetFailState("Failed to create dynamic hook");
	}
	DHookAddParam(_dh, HookParamType_CBaseEntity);

	if (_late)
	{
		for (int client = 1; client <= MaxClients; ++client)
		{
			if (IsClientInGame(client))
			{
				HookBumpWeapon(client);
				HookTakeDmg(client);
			}
		}
	}
	
	AutoExecConfig(true);
}

void HookBumpWeapon(int client)
{
	if (INVALID_HOOK_ID == DHookEntity(_dh, true, client, _, BumpWeapon))
	{
		SetFailState("Failed to hook entity");
	}
}

void HookTakeDmg(int client)
{
	if (!SDKHookEx(client, SDKHook_OnTakeDamage, OnTakeDamage))
	{
		SetFailState("Failed to SDKHook");
	}
}

public Action OnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype, int& weapon, float damageForce[3], float damagePosition[3])
{
	if (damagetype != DMGTYPE_SMAC) // Seems to be unique to SMAC and doesn't change depending on which hitbox you hit (high, mid, low)
	{
		return Plugin_Continue;
	}
	
	if(damageForce[2] == 0.0) // This will be 0.0 on self-damage from smac but otherwise not
	{
		return Plugin_Handled;
	}
	
	int health = GetEntProp(victim, Prop_Send, "m_iHealth");
	int dmg = _smac_dmg.IntValue;
	
	if(health <= dmg + 1)
	{
		return Plugin_Continue;
	}
	
	RequestFrame(TakeSmacHit, victim);

	return Plugin_Handled;
}

public void OnClientPutInServer(int client)
{
	HookBumpWeapon(client);
	HookTakeDmg(client);
}

void TakeSmacHit(int victim)
{
	if (!victim || !IsClientInGame(victim) || !IsPlayerAlive(victim))
	{
		return;
	}

	int health = GetEntProp(victim, Prop_Send, "m_iHealth");
	//PrintToChatAll("Health: %d", health);
	int dmg = _smac_dmg.IntValue;
	health -= dmg;
	// because NT internally considers "dead" as being 1HP, not 0
	if (health > 1)
	{
		SetEntProp(victim, Prop_Send, "m_iHealth", health);
	}
}

public MRESReturn BumpWeapon(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (hReturn.Value)
	{
		return MRES_Ignored;
	}

	int weapon = hParams.Get(1);
	if (!IsValidEdict(weapon))
	{
		return MRES_Ignored;
	}

	char cls[11 + 1];
	if (!GetEdictClassname(weapon, cls, sizeof(cls)) ||
		!StrEqual(cls, "weapon_smac"))
	{
		return MRES_Ignored;
	}

	int weps_size = GetEntPropArraySize(pThis, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < weps_size; ++i)
	{
		int w = GetEntPropEnt(pThis, Prop_Send, "m_hMyWeapons", i);
		if (GetWeaponSlot(w) == SLOT_PRIMARY)
		{
			return MRES_Ignored;
		}
	}

	char vipNameBuff[32]; 
	bool vipOnly = _smac_vip_only.BoolValue;
	GetEntPropString(pThis, Prop_Data, "m_iName", vipNameBuff, sizeof(vipNameBuff));
	
	if (vipOnly && !StrEqual("vip_player", vipNameBuff, false))
	{
		return MRES_Ignored;
	}
	
	static Handle call = INVALID_HANDLE;
	if (call == INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Player);
		char sig[] = "\x56\x8B\x74\x24\x08\x57\x8B\xF9\x8B\xCE\xE8\x2A\x2A\x2A\x2A\x8B\x8F\xA8\x00\x00\x00";
		PrepSDKCall_SetSignature(SDKLibrary_Server, sig, sizeof(sig) - 1);
		PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
		PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
		call = EndPrepSDKCall();
		if (call == INVALID_HANDLE)
		{
			SetFailState("Failed to prepare SDK call");
		}
	}
	hReturn.Value = SDKCall(call, pThis, weapon);

	return MRES_Supercede;
}
