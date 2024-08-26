#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <neotokyo>

#define DEBUG true
#define PRNT_SRVR (1<<0)
#define PRNT_CNSL (1<<1)
#define PRNT_CHT (1<<2)
#define PRNT_ALL 7

#define GAMEHUD_TIE 3
#define GAMEHUD_JINRAI 4
#define GAMEHUD_NSF 5
#define BOTH_TEAMS 5

public Plugin myinfo = {
	name = "NT VIP mode",
	description = "Enabled VIP game mode mode for VIP maps, SMAC plugin required",
	author = "bauxite, Credits to Destroygirl, Agiel, Rain, SoftAsHell",
	version = "0.7.6",
	url = "https://github.com/bauxiteDYS/SM-NT-VIP",
};

static char g_vipName[] = "vip_player";
DynamicDetour ddWin;
Handle VipCreateTimer;
int g_oldVipClass;
int g_vipPlayer = -1;
int g_vipTeam = -1;
int g_opsTeam = -1;
int g_vipKiller = -1;
bool g_lateLoad;
bool g_vipMap;
bool g_vipEscaped;

int GetOpposingTeam(int team)
{
    return team == TEAM_JINRAI ? TEAM_NSF : TEAM_JINRAI;
}

int FindEntityByTargetname(const char[] classname, const char[] targetname)
{
	int ent = -1;
	char buffer[64];
	
	while ((ent = FindEntityByClassname(ent, classname)) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", buffer, sizeof(buffer));

		if (StrEqual(buffer, targetname))
		{
			return ent;
		}
	}

	return -1;
}

bool IsPlayerDead(int client) // Agiel: None of the normal ways seemed to handle the case when players are still selecting weapon.
{
    Address player = GetEntityAddress(client);
    int isAlive = LoadFromAddress(player + view_as<Address>(0xDC4), NumberType_Int32);
    return isAlive == 0;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_lateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	if(g_lateLoad)
	{
		OnMapInit();
	}
}

public void OnMapInit()
{	
	static bool deathHook;
	static bool roundHook;
	char mapName[32];
	GetCurrentMap(mapName, sizeof(mapName));
	
	if(StrContains(mapName, "_vip", false) != -1)
	{
		g_vipMap = true;
		ServerCommand("sm plugins unload nt_wincond"); 
		
		if(HookEventEx("player_death", Event_PlayerDeathPre, EventHookMode_Pre))
		{
			deathHook = true;
		}
		
		if(HookEvent("game_round_start", OnRoundStartPost, EventHookMode_Post))
		{
			roundHook = true;
		}
		
		CreateDetour();
	}
	else
	{
		g_vipMap = false;
		
		if(deathHook && roundHook)
		{
			UnhookEvent("player_death", Event_PlayerDeathPre, EventHookMode_Pre);
			UnhookEvent("game_round_start", OnRoundStartPost, EventHookMode_Post);
			deathHook = false;
			roundHook = false;
		}

		DisableDetour();		
	}
}

void DisableDetour() 
{
	if(!IsValidHandle(ddWin))
	{
		return;
	}
	
	if(!ddWin.Disable(Hook_Pre, CheckWinCondition))	
	{
		return;
	}
	
	delete ddWin;
}

void CreateDetour() 
{
	Handle gd = LoadGameConfigFile("neotokyo/wincond");

	if (gd == INVALID_HANDLE) 
	{
		SetFailState("Failed to load GameData");
	}

	ddWin = DynamicDetour.FromConf(gd, "Fn_CheckWinCondition");
	
	if(!ddWin) 
	{
		SetFailState("Failed to create dynamic detour");
	}
	
	if(!ddWin.Enable(Hook_Pre, CheckWinCondition))	
	{
		SetFailState("Failed to detour");
	}

	CloseHandle(gd);
}

MRESReturn CheckWinCondition(Address pThis, DHookReturn hReturn)
{
	if(CheckingForWin())
	{
		return MRES_Supercede;
	}
	
	return MRES_Handled;
}

bool CheckingForWin() 
{
	int aliveJinrai = 0;
	int aliveNsf = 0;
	
	for (int i = 1; i <= MaxClients; i++) 
	{
		if (IsClientInGame(i) && !IsPlayerDead(i))
		{
			int team = GetClientTeam(i);
			
			if (team == TEAM_JINRAI) 
			{
				++aliveJinrai;
			} 
			else if (team == TEAM_NSF) 
			{
				++aliveNsf;
			}
		}
	}
	
	if(aliveNsf == 0 && aliveJinrai == 0)
	{
		PrintMsg("[VIP] Somehow both teams died at the same time", PRNT_CHT | PRNT_CNSL);
		EndRoundAndShowWinner(BOTH_TEAMS);
		return true;
	}
	
	if (aliveNsf == 0)
	{
		PrintMsg("[VIP] Win by elimination", PRNT_CHT | PRNT_CNSL);
		EndRoundAndShowWinner(TEAM_JINRAI);
		return true;
	}
	
	if (aliveJinrai == 0) 
	{
		PrintMsg("[VIP] Win by elimination", PRNT_CHT | PRNT_CNSL);
		EndRoundAndShowWinner(TEAM_NSF);
		return true;
	}
	
	float roundTimeLeft = GameRules_GetPropFloat("m_fRoundTimeLeft");
	
	if (roundTimeLeft == 0.0)
	{
		PrintMsg("[VIP] Tie", PRNT_CHT | PRNT_CNSL);
		EndRoundAndShowWinner(BOTH_TEAMS);
		return true;
	}
	
	return false;
}

public void OnRoundStartPost(Event event, const char[] name, bool dontBroadcast)
{
	if(!g_vipMap)
	{
		return;
	}
	#if DEBUG
	PrintMsg("[VIP Debug] New round started", PRNT_SRVR);
	#endif
	int trigger = FindEntityByTargetname("trigger_once", "vip_escape_point");
	HookSingleEntityOutput(trigger, "OnStartTouch", Trigger_OnStartTouch);
	
	ClearWin();
	ClearVip();
	ClearTimer();
	
	VipCreateTimer = CreateTimer(9.0, Timer_CreateVip);
}

public Action Timer_CreateVip(Handle timer)
{
	int GameState = GameRules_GetProp("m_iGameState");
	
	if(GameState == GAMESTATE_ROUND_OVER || GameState == GAMESTATE_WAITING_FOR_PLAYERS)
	{
		return Plugin_Stop;
	}
	
	SelectVip();
	
	#if DEBUG
	PrintMsg("[VIP Debug] VIP Timer, trying to select VIP, GameState: %d", PRNT_SRVR | PRNT_CNSL, GameState);
	#endif
	return Plugin_Stop;
}

void SelectVip()
{
	static int lastJinraiVip;
	static int lastNSFVip;
	
	bool nsfDupVIP;
	bool jinDupVIP;
	
	int atkTeam = GameRules_GetProp("m_iAttackingTeam");
	int vipList[NEO_MAXPLAYERS];
	int vipCount;
	int randVip;
	
	for(int client = 1; client <= MaxClients; client++)
	{
		if(!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client) || GetClientTeam(client) != atkTeam)
		{
			continue;
		}
		
		if(atkTeam == TEAM_NSF && lastNSFVip == client)
		{
			nsfDupVIP = true;
			continue;
		}
		else if(atkTeam == TEAM_JINRAI && lastJinraiVip == client)
		{
			jinDupVIP = true;
			continue;
		}
		vipList[vipCount] = client;
		vipCount++;
	}
	#if DEBUG
	PrintMsg("[VIP Debug] Potential VIPs found: %d", PRNT_SRVR | PRNT_CNSL, vipCount);
	#endif
	if(jinDupVIP && vipCount == 0)
	{
		vipList[vipCount] = lastJinraiVip;
		vipCount++;
	}
	else if (nsfDupVIP && vipCount == 0)
	{
		vipList[vipCount] = lastNSFVip;
		vipCount++;
	}
	
	if(vipCount == 0)
	{
		PrintMsg("[VIP] It seems no VIP spawned, TDM mode this round", PRNT_CHT | PRNT_CNSL);
		return;
	}
	else if(vipCount == 1)
	{	
		SetVip(vipList[0]);
		
		if(atkTeam == TEAM_NSF)
		{
			lastNSFVip = vipList[0];
		}
		else
		{
			lastJinraiVip = vipList[0];
		}
		
		return;
	}
	else if(vipCount >= 2)
	{
		randVip = GetRandomInt(0, vipCount-1); // the vipcount is 1 higher than the array position
		SetVip(vipList[randVip]);
		
		if(atkTeam == TEAM_NSF)
		{
			lastNSFVip = vipList[randVip];
		}
		else
		{
			lastJinraiVip = vipList[randVip];
		}
		
		return;
	}
}

void ClearWin()
{
	g_vipKiller = -1;
	g_vipEscaped = false;
}

void ClearVip()
{
	if(g_vipPlayer > 0)
	{
		if(IsClientInGame(g_vipPlayer))
		{
			DispatchKeyValue(g_vipPlayer, "targetname", "RndPlyr");
			SDKUnhook(g_vipPlayer, SDKHook_WeaponDrop, OnWeaponDrop)
		}
	}
	
	g_vipPlayer = -1;
	g_vipTeam = -1;
	g_opsTeam = -1;
	g_oldVipClass = 0;
}

void ClearTimer()
{
	if(IsValidHandle(VipCreateTimer))
	{
		CloseHandle(VipCreateTimer);
		VipCreateTimer = null;
		#if DEBUG
		PrintMsg("[VIP Debug] Killing Timer", PRNT_SRVR);
		#endif
	}
}

void SetVip(int theVip)
{
	int GameState = GameRules_GetProp("m_iGameState");
	
	if(GameState == GAMESTATE_ROUND_OVER || GameState == GAMESTATE_WAITING_FOR_PLAYERS)
	{
		#if DEBUG
		PrintMsg("[VIP Debug] Can't set VIP as round is not active", PRNT_ALL);
		#endif
		return;
	}
	
	if(!IsClientInGame(theVip))
	{
		#if DEBUG
		PrintMsg("[VIP Debug] Can't set client: %d as VIP as they are not in-game", PRNT_ALL, theVip);
		#endif
		//SelectVip();
		return;
	}
	
	g_vipPlayer = theVip;
	g_vipTeam = GetClientTeam(theVip);
	g_opsTeam = GetOpposingTeam(g_vipTeam);
	PrintMsg("[VIP] VIP Team: %s, VIP player: %N", PRNT_CHT | PRNT_CNSL, g_vipTeam == TEAM_NSF ? "NSF" : "Jinrai", theVip);
	MakeVip(theVip);
}

void MakeVip(int vip)
{
	if(!IsClientInGame(vip))
	{
		//ClearVip(); let disconnect hook handle this
		return;
	}
	
	int class = GetPlayerClass(vip);
	
	if(class != 2)
	{
		if(!GameRules_GetProp("m_bFreezePeriod"))
		{
			return;
		}
		
		g_oldVipClass = class;
		
		ForceClass(vip);
		return;
	}
	
	SetupVIP(vip);
}

void SetupVIP(int vip)
{
	if(!IsClientInGame(vip))
	{
		//ClearVip(); let disconnect hook handle this
		return;
	}
	
	StripPlayerWeapons(vip, false); // No VIP animations for knife
	int newWeapon = GivePlayerItem(vip, "weapon_smac"); 

	if(newWeapon != -1)
	{
		AcceptEntityInput(newWeapon, "use", vip, vip);
	}
	
	char vipModel[] = "models/player/vip.mdl";
	SetEntityModel(vip, vipModel);
	DispatchKeyValue(vip, "targetname", g_vipName); // Same as "m_iName" but can't set that directly first otherwise server crash
	SetEntityHealth(vip, 120);
	SetEntProp(newWeapon, Prop_Data, "m_iClip1", 190);
	SDKHook(vip, SDKHook_WeaponDrop, OnWeaponDrop);
	
	#if DEBUG
	int class = GetPlayerClass(vip);
	if(class != 2)
	{
		PrintMsg("[VIP Debug] Somehow set vip to the wrong class: %d", PRNT_ALL, class);
	}
	#endif
	
	FakeClientCommand(vip, "setclass %d", g_oldVipClass);
	FakeClientCommand(vip, "setvariant 2");
	FakeClientCommand(vip, "loadout 0");
}

void ForceClass(int client)
{
	if(!IsClientInGame(client))
	{
		//ClearVip(); let disconnect hook handle this
		return;
	}
	
	StripPlayerWeapons(client, false);
	RequestFrame(RespawnNewClass, client); // does this need to be delayed by a frame?
}

void RespawnNewClass(int client)
{
	if(!IsClientInGame(client))
	{
		//ClearVip(); let disconnect hook handle this
		return;
	}

	SetNewClassProps(client);
	static Handle call = INVALID_HANDLE;
	
	if (call == INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Player);
		PrepSDKCall_SetSignature(SDKLibrary_Server, "\x56\x8B\xF1\x8B\x06\x8B\x90\xBC\x04\x00\x00\x57\xFF\xD2\x8B\x06", 16);
		call = EndPrepSDKCall();
		if (call == INVALID_HANDLE)
		{
			SetFailState("Failed to prepare SDK call");
		}
	}
	
	SDKCall(call, client);
	RequestFrame(SetupVIP, client);
}

SetNewClassProps(int client)
{
	FakeClientCommand(client, "setclass 2");
	FakeClientCommand(client, "setvariant 2");
	FakeClientCommand(client, "loadout 0");
	SetEntProp(client, Prop_Send, "m_iLives", 1);
	SetEntProp(client, Prop_Data, "m_iObserverMode", 0);
	SetEntProp(client, Prop_Data, "m_iHealth", 100);
	SetEntProp(client, Prop_Data, "m_lifeState", 0);
	SetEntProp(client, Prop_Data, "m_fInitHUD", 1);
	SetEntProp(client, Prop_Data, "m_takedamage", 2);
	SetEntProp(client, Prop_Send, "deadflag", 0);
	SetEntPropFloat(client, Prop_Send, "m_flDeathTime", 0.0);
	SetEntPropEnt(client, Prop_Data, "m_hObserverTarget", -1, 0);
}

public Action OnWeaponDrop(int client, int weapon)
{
	if(!g_vipMap)
	{
		return Plugin_Continue;
	}
	
	// Other classes have no SMAC animation so make VIP unable to drop it
	// Also VIP has no other weapons and are meant to use the SMAC
	// So not going to allow them to drop it for now
	// It's unhooked automatically if they leave server
	// Should use SMAC plugin to disallow other classes from picking it up after VIP death
	
	return Plugin_Handled;
}

public void OnClientDisconnect_Post(int client)
{
	if(!g_vipMap)
	{
		return;
	}
	
	if(g_vipPlayer == client)
	{
		ClearVip();
		PrintMsg("[VIP] VIP disconnected, TDM mode for now", PRNT_CHT | PRNT_CNSL);
	}
}

public Action Event_PlayerDeathPre(Event event, const char[] name, bool dontBroadcast)
{
	if(!g_vipMap)
	{
		return Plugin_Continue;
	}
	
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	int GameState = GameRules_GetProp("m_iGameState");
	
	if(GameState == GAMESTATE_WAITING_FOR_PLAYERS)
	{
		return Plugin_Continue;
	}
	
	if(g_vipEscaped)
	{
		return Plugin_Continue;
	}
	
	if(victim == g_vipPlayer)
	{
		if(attacker != victim && attacker > 0)
		{
			g_vipKiller = attacker;
			PrintMsg("[VIP] VIP was killed by %N!", PRNT_CHT | PRNT_CNSL, attacker);
		}
		else
		{
			PrintMsg("[VIP] VIP died!", PRNT_CHT | PRNT_CNSL);
		}
		
		EndRoundAndShowWinner(g_opsTeam);
		
		return Plugin_Continue;
	}
	else if(g_vipPlayer >= 1 && IsPlayerDead(g_vipPlayer)) 
	{
		PrintMsg("[VIP] Error: VIP somehow died??!", PRNT_CHT | PRNT_CNSL);
		EndRoundAndShowWinner(g_opsTeam);
		
		return Plugin_Continue; // double check cos I think first check fails in rare occasion? (dunno?) - is it a problem?
	}

	return Plugin_Continue;
}

void Trigger_OnStartTouch(const char[] output, int caller, int activator, float delay)
{
	if(g_vipPlayer == activator)
	{
		g_vipEscaped = true;
		EndRoundAndShowWinner(g_vipTeam);
		PrintMsg("[VIP] VIP escaped!", PRNT_CHT | PRNT_CNSL);
	}
}

void EndRoundAndShowWinner(int team) //what about during comp pause
{
	int GameState = GameRules_GetProp("m_iGameState");
	
	if(GameState == GAMESTATE_ROUND_OVER || GameState == GAMESTATE_WAITING_FOR_PLAYERS)
	{
		#if DEBUG
		PrintMsg("[VIP Debug] Error: Awarding win when round is over", PRNT_ALL);
		#endif
		return;
	}
	
	if(team != TEAM_JINRAI && team != TEAM_NSF && team != BOTH_TEAMS)
	{
		#if DEBUG
		PrintMsg("[VIP Debug] Error: Awarding win to unknown team: %d", PRNT_ALL, team);
		#endif
		return;
	}
	
	ClearTimer();
	
	GameRules_SetProp("m_iGameState", GAMESTATE_ROUND_OVER);
	GameRules_SetPropFloat( "m_fRoundTimeLeft", 15.0 );
	
	if(team == BOTH_TEAMS)
	{
		GameRules_SetProp("m_iGameHud", GAMEHUD_TIE);
	
		if(g_vipPlayer > 0)
		{
			PrintMsg("[VIP] VIP Survived!", PRNT_CHT | PRNT_CNSL);
		}
	}
	else
	{
		GameRules_SetProp("m_iGameHud", team + 2);
		
		int score = GetTeamScore(team);
		SetTeamScore(team, score + 1);
	}
	
	RewardPlayers(team);
}

void RewardPlayers(int winTeam)
{
	// Rewards need a rework
	
	int bonusPoints = 2;
	int newPoints;
	
	if(g_vipKiller > 0 && g_vipEscaped)
	{
		#if DEBUG
		PrintMsg("[VIP Debug] Error: Can't set player rewards as VIP was killed but also escaped somehow", PRNT_ALL);
		#endif
		return;
	}
	
	if(g_vipKiller > 0 && IsClientInGame(g_vipKiller))
	{
		int xp = GetPlayerXP(g_vipKiller) + bonusPoints;
		SetPlayerXP(g_vipKiller, xp);
		PrintMsg("[VIP] Giving bonus XP to %N for killing VIP", PRNT_CHT | PRNT_CNSL, g_vipKiller);
	}
	
	if(g_vipEscaped && IsClientInGame(g_vipPlayer))
	{
		int xp = GetPlayerXP(g_vipPlayer) + bonusPoints;
		SetPlayerXP(g_vipPlayer, xp);
		PrintMsg("[VIP] Giving bonus XP to %N for escaping", PRNT_CHT | PRNT_CNSL, g_vipPlayer);
	}
	
	if(winTeam == TEAM_JINRAI || winTeam == TEAM_NSF)
	{
		newPoints = 2;
		PrintMsg("[VIP] Team %s got a reward for winning", PRNT_CHT | PRNT_CNSL, winTeam == TEAM_NSF ? "NSF" : "Jinrai");
	}
	else if(winTeam == BOTH_TEAMS)
	{
		newPoints = 1;
		PrintMsg("[VIP] Both teams got a small reward for tie", PRNT_CHT | PRNT_CNSL);
	}
	else
	{
		return;
	}
	
	for(int client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && (GetClientTeam(client) == winTeam || winTeam == 5))
		{
			int xp = GetPlayerXP(client) + newPoints;
			SetPlayerXP(client, xp);
		}
	}
	
	ClearVip();
	ClearWin();
}

void PrintMsg(const char[] msg, int flags, any ...)
{
	char debugMsg[128];
	
	VFormat(debugMsg, sizeof(debugMsg), msg, 3);
	
	if (flags & PRNT_SRVR)
	{
	PrintToServer(debugMsg);
	}

	if (flags & PRNT_CHT)
	{
		PrintToChatAll(debugMsg);
	}

	if (flags & PRNT_CNSL)
	{
		PrintToConsoleAll(debugMsg);
	}
}
