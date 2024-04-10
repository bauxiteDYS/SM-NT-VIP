#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <neotokyo>
#include <nt_competitive/nt_competitive_natives>

#define GAMEHUD_TIE 3
#define GAMEHUD_JINRAI 4
#define GAMEHUD_NSF 5

#define BOTH_TEAMS 5

public Plugin myinfo = {
	name = "NT VIP mode",
	description = "Enabled VIP game mode mode for VIP maps, smac plugin required",
	author = "bauxite, Credits to Destroygirl, Agiel, Rain, SoftAsHell",
	version = "0.5.0",
	url = "https://github.com/bauxiteDYS/SM-NT-VIP",
};

static char g_vipName[] = "vip_player";

Handle VipCheckTimer;

int g_vipPlayer = -1;
int g_vipTeam = -1;
int g_opsTeam = -1;
int g_vipKiller = -1;

bool g_vipEscaped;
bool g_checkPassed;

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

public void OnPluginStart()
{
	CreateDetour();
	
	HookEvent("player_death", Event_PlayerDeathPre, EventHookMode_Pre);
	HookEvent("game_round_start", OnRoundStartPost, EventHookMode_Post);
	HookEvent("player_spawn", OnPlayerSpawnPost, EventHookMode_Post);
}

public void OnMapInit()
{	
	char mapName[32];
	GetCurrentMap(mapName, sizeof(mapName));
	
	if(StrContains(mapName, "_vip", false) != -1)
	{
		ServerCommand("sm plugins unload nt_wincond"); 
		PrintToServer("%s is a vip map, unloading wincond plugin for now", mapName);
	}
	else
	{
		SetFailState("Not a vip map");
	}
}

void CreateDetour() 
{
    Handle gd = LoadGameConfigFile("neotokyo/wincond");
	
    if (gd == INVALID_HANDLE) 
	{
        SetFailState("Failed to load GameData");
    }
	
    DynamicDetour dd = DynamicDetour.FromConf(gd, "Fn_CheckWinCondition");
	
    if (!dd) 
	{
        SetFailState("Failed to create dynamic detour");
    }
	
    if (!dd.Enable(Hook_Pre, CheckWinCondition))	
	{
        SetFailState("Failed to detour");
    }
	
    delete dd;
    CloseHandle(gd);
}

MRESReturn CheckWinCondition(Address pThis, DHookReturn hReturn)
{
	CheckingForWin();
	return MRES_Supercede;
}

void CheckingForWin() 
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
	
	if (aliveNsf == 0)
	{
		PrintToChatAll("Win by elimination");
		EndRoundAndShowWinner(TEAM_JINRAI);
		return;
	}
	
	if (aliveJinrai == 0) 
	{
		PrintToChatAll("Win by elimination");
		EndRoundAndShowWinner(TEAM_NSF);
		return;
	}
	
	float roundTimeLeft = GameRules_GetPropFloat("m_fRoundTimeLeft");
	
	if (roundTimeLeft == 0.00)
	{
		PrintToChatAll("Tie");
		EndRoundAndShowWinner(BOTH_TEAMS);
		return;
	}
}

public void OnRoundStartPost(Event event, const char[] name, bool dontBroadcast)
{
	int trigger = FindEntityByTargetname("trigger_once", "vip_escape_point");
	HookSingleEntityOutput(trigger, "OnStartTouch", Trigger_OnStartTouch);
	
	ClearWin();
	ClearVip();
	ClearTimer();
	
	VipCheckTimer = CreateTimer(35.0, CheckForVip, _, TIMER_FLAG_NO_MAPCHANGE); // Players can spawn for about 33s into the round
}

public Action CheckForVip(Handle timer)
{
	if(g_vipPlayer == -1)
	{
		PrintToChatAll("It seems no VIP spawned, TDM mode this round");
	}
	
	return Plugin_Stop;
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
		}
	}
	
	g_vipPlayer = -1;
	g_vipTeam = -1;
	g_opsTeam = -1;
	
	g_checkPassed = false;
}

void ClearTimer()
{
	if(IsValidHandle(VipCheckTimer))
	{
		CloseHandle(VipCheckTimer);
	}
}

public void OnPlayerSpawnPost(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if(g_vipPlayer == -1)
	{
		RequestFrame(CheckClassAndSetVip, client);
	}
}

void CheckClassAndSetVip(int client)
{
	int atkTeam = GameRules_GetProp("m_iAttackingTeam");
	int class = GetPlayerClass(client);
	
	if(GetClientTeam(client) == atkTeam && class == CLASS_ASSAULT && !g_checkPassed)
	{
		g_checkPassed = true;
		RequestFrame(SetVip, client);
	}	
}

void SetVip(int theVip)
{
	if(theVip <= 0)
	{
		g_checkPassed = false;
		PrintToChatAll("Tried to set VIP to invalid client");
		return;
	}
	
	if(!IsClientInGame(theVip))
	{
		g_checkPassed = false;
		PrintToChatAll("Tried to set VIP to a player not in the game");
		return;
	}
	
	if(g_vipPlayer != -1)
	{
		PrintToChatAll("Tried to set VIP when one already exists, it needs to be cleared first");
		return;
	}
	
	g_vipPlayer = theVip;
	g_vipTeam = GetClientTeam(theVip);
	g_opsTeam = GetOpposingTeam(g_vipTeam);
	
	PrintToChatAll("VIP Team: %s, VIP player: %N", g_vipTeam == TEAM_NSF ? "NSF" : "Jinrai", theVip);
	
	MakeVip(theVip);
}

void MakeVip(int vip)
{
	StripPlayerWeapons(vip, true);
	
	int newWeapon = GivePlayerItem(vip, "weapon_smac");

	if(newWeapon != -1)
	{
		AcceptEntityInput(newWeapon, "use", vip, vip);
	}
	
	char vipModel[] = "models/player/vip.mdl";
	SetEntityModel(vip, vipModel);
	DispatchKeyValue(vip, "targetname", g_vipName);
	
	SetEntityHealth(vip, 120);
	
	SetEntProp(newWeapon, Prop_Data, "m_iClip1", 190);
}

public void OnClientDisconnect_Post(int client)
{
	if(g_vipPlayer == client)
	{
		ClearVip();
		PrintToChatAll("VIP disconnected, TDM mode for now? (probably)!");
	}
}

public Action Event_PlayerDeathPre(Event event, const char[] name, bool dontBroadcast)
{
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
			PrintToChatAll("VIP was killed by %N!", attacker);
		}
		else
		{
			PrintToChatAll("VIP died!");
		}
		
		EndRoundAndShowWinner(g_opsTeam);
		
		return Plugin_Continue;
	}
	else if(g_vipPlayer >= 1 && IsPlayerDead(g_vipPlayer)) 
	{
		PrintToChatAll("VIP somehow died??!");
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
		PrintToChatAll("VIP escaped!");
	}
}

void EndRoundAndShowWinner(int team) //what about during comp pause
{
	int GameState = GameRules_GetProp("m_iGameState");
	
	if(GameState == GAMESTATE_ROUND_OVER || GameState == GAMESTATE_WAITING_FOR_PLAYERS)
	{
		PrintToChatAll("round is already over or hasn't started yet?");
		return;
	}
	
	if(team != TEAM_JINRAI && team != TEAM_NSF && team != BOTH_TEAMS)
	{
		PrintToChatAll("Something went wrong, trying to show winner of unknown team");
		return;
	}
	
	GameRules_SetProp("m_iGameState", GAMESTATE_ROUND_OVER);
	GameRules_SetPropFloat( "m_fRoundTimeLeft", 15.0 );
	
	if(team == BOTH_TEAMS)
	{
		GameRules_SetProp("m_iGameHud", GAMEHUD_TIE);
	
		if(g_vipPlayer > 0)
		{
			PrintToChatAll("VIP Survived!");
		}
	}
	else
	{
		GameRules_SetProp("m_iGameHud", team + 2);
		
		int score = GetTeamScore(team);
		SetTeamScore(team, score + 1);
	}
	
	RewardPlayers(team);
	
	ClearTimer();
}

void RewardPlayers(int winTeam)
{
	// Rewards need a rework
	
	int bonusPoints = 2;
	int newPoints;
	
	if(g_vipKiller > 0 && g_vipEscaped)
	{
		PrintToChatAll("Something went wrong with the player rewards");
		PrintToConsoleAll("Something went wrong with the player rewards");
	}
	
	if(g_vipKiller > 0 && IsClientInGame(g_vipKiller))
	{
		int xp = GetPlayerXP(g_vipKiller) + bonusPoints;
		SetPlayerXP(g_vipKiller, xp);
		PrintToChatAll("Giving bonus XP to %N for killing VIP", g_vipKiller);
	}
	
	if(g_vipEscaped && IsClientInGame(g_vipPlayer))
	{
		int xp = GetPlayerXP(g_vipPlayer) + bonusPoints;
		SetPlayerXP(g_vipPlayer, xp);
		PrintToChatAll("Giving bonus XP to %N for escaping", g_vipPlayer);
	}
	
	if(winTeam == TEAM_JINRAI || winTeam == TEAM_NSF)
	{
		newPoints = 2;
		PrintToChatAll("Team %s got a reward for winning", winTeam == TEAM_NSF ? "NSF" : "Jinrai");
	}
	else if(winTeam == BOTH_TEAMS)
	{
		newPoints = 1;
		PrintToChatAll("Both teams got a small reward for tie");
	}
	else
	{
		PrintToChatAll("Error, tried to reward players on invalid team");
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
